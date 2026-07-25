//! Package identity, manifests, and signatures.
//!
//! A package's identity is derived from its contents, not asserted by its
//! metadata. Two builds producing identical bytes have the same identity, and
//! changing one byte changes it — so an identity cannot be reused to ship
//! different code, and a substituted artifact does not resolve to what the
//! system expected.
//!
//! A manifest declares the capabilities a package would like. Declaring is
//! asking: installation shows the declaration, and runtime policy decides what
//! is actually granted. A manifest asking for everything therefore gains
//! nothing except a visible reason to refuse it.
//!
//! Unsigned packages are refused outside explicit development mode, and
//! development mode is a decision the caller passes in rather than a state the
//! verifier infers.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const capability_model = @import("../capability/capability.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;
pub const digest_bytes = Sha256.digest_length;

pub const max_name_bytes: usize = 128;
pub const max_publisher_bytes: usize = 128;
pub const max_declared_capabilities: usize = 64;

pub const Error = error{
    /// The signature does not verify against the publisher's key.
    IntegrityFailure,
    /// The package is unsigned and development mode was not requested.
    UnsignedPackageRefused,
    /// The publisher is not one this host installs from.
    UnknownPublisher,
    /// The contents do not hash to the declared identity.
    IdentityMismatch,
    /// The manifest is malformed or exceeds a declared bound.
    InvalidManifest,
    /// A newer version of this package is already installed.
    RollbackRefused,
};

/// A package's content-derived identity.
///
/// Deterministic: the same bytes always produce the same value, on any host,
/// with no salt and no timestamp. That is what makes it comparable between the
/// publisher, the installer, and a later audit.
pub const Identity = struct {
    digest: [digest_bytes]u8,

    pub fn ofContents(contents: []const u8) Identity {
        var value: Identity = .{ .digest = undefined };
        Sha256.hash(contents, &value.digest, .{});
        return value;
    }

    pub fn eql(value: Identity, other: Identity) bool {
        // Constant-time: an installer comparing identities should not leak
        // where two candidates first differ.
        return std.crypto.timing_safe.eql([digest_bytes]u8, value.digest, other.digest);
    }

    pub fn format(value: Identity, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{x}", .{value.digest});
    }
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn order(version: Version, other: Version) std.math.Order {
        if (version.major != other.major) return std.math.order(version.major, other.major);
        if (version.minor != other.minor) return std.math.order(version.minor, other.minor);
        return std.math.order(version.patch, other.patch);
    }

    pub fn isNewerThan(version: Version, other: Version) bool {
        return version.order(other) == .gt;
    }
};

/// A capability a package asks for. Not a grant.
pub const DeclaredCapability = struct {
    resource_kind: []const u8,
    operations: capability_model.OperationSet,
    /// Why the package says it needs this, shown at installation.
    justification: []const u8,
    /// Whether the package can function without it.
    optional: bool = false,
};

/// What a package says about itself.
pub const Manifest = struct {
    name: []const u8,
    publisher: []const u8,
    version: Version,
    /// Capabilities requested, never guaranteed.
    declared_capabilities: []const DeclaredCapability,
    /// Network destinations the package expects to reach.
    network_destinations: []const []const u8 = &.{},
    /// Whether the package runs work outside a foreground task.
    runs_in_background: bool = false,
    /// Deepest delegation the package may perform.
    max_delegation_depth: u8 = 0,

    /// Checks the manifest's own bounds before anything acts on it.
    pub fn validate(manifest: Manifest) Error!void {
        if (manifest.name.len == 0 or manifest.name.len > max_name_bytes) {
            return error.InvalidManifest;
        }
        if (manifest.publisher.len == 0 or manifest.publisher.len > max_publisher_bytes) {
            return error.InvalidManifest;
        }
        if (manifest.declared_capabilities.len > max_declared_capabilities) {
            return error.InvalidManifest;
        }
        for (manifest.declared_capabilities) |declared| {
            if (declared.resource_kind.len == 0) return error.InvalidManifest;
            if (declared.justification.len == 0) return error.InvalidManifest;
        }
    }

    /// Capabilities the package cannot run without.
    pub fn requiredCount(manifest: Manifest) usize {
        var required: usize = 0;
        for (manifest.declared_capabilities) |declared| {
            if (!declared.optional) required += 1;
        }
        return required;
    }

    /// The digest a signature commits to: every manifest field and the contents,
    /// bound together. Signing only the contents would leave the declared
    /// capabilities, network destinations, version, publisher, and delegation
    /// depth free to be altered on an otherwise validly-signed package, so the
    /// whole manifest is folded in here. Fields are fed canonically — a domain
    /// tag first, then each field length-prefixed or fixed-width — so two
    /// distinct manifests can never hash the same way and no field boundary is
    /// ambiguous.
    pub fn signingDigest(manifest: Manifest, contents: []const u8) [digest_bytes]u8 {
        var hasher = Sha256.init(.{});
        hasher.update("package.manifest.signature.v1");
        hashField(&hasher, manifest.name);
        hashField(&hasher, manifest.publisher);
        hashInt(&hasher, u32, manifest.version.major);
        hashInt(&hasher, u32, manifest.version.minor);
        hashInt(&hasher, u32, manifest.version.patch);
        hashInt(&hasher, u8, @intFromBool(manifest.runs_in_background));
        hashInt(&hasher, u8, manifest.max_delegation_depth);

        hashInt(&hasher, u32, @intCast(manifest.declared_capabilities.len));
        for (manifest.declared_capabilities) |declared| {
            hashField(&hasher, declared.resource_kind);
            hashInt(&hasher, u64, operationBits(declared.operations));
            hashField(&hasher, declared.justification);
            hashInt(&hasher, u8, @intFromBool(declared.optional));
        }

        hashInt(&hasher, u32, @intCast(manifest.network_destinations.len));
        for (manifest.network_destinations) |destination| {
            hashField(&hasher, destination);
        }

        // The contents' own digest, so a signature over the manifest is also a
        // signature over exactly these bytes.
        var contents_digest: [digest_bytes]u8 = undefined;
        Sha256.hash(contents, &contents_digest, .{});
        hasher.update(&contents_digest);

        var digest: [digest_bytes]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }
};

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    hasher.update(&buffer);
}

/// A length-prefixed field: the u32 length first, then the bytes, so a field's
/// contents can never be confused with the start of the next field.
fn hashField(hasher: *Sha256, bytes: []const u8) void {
    hashInt(hasher, u32, @intCast(bytes.len));
    hasher.update(bytes);
}

/// The operation set as a stable integer, so the exact set of permitted
/// operations is committed to. The enum has at most 64 members.
fn operationBits(operations: capability_model.OperationSet) u64 {
    var bits: u64 = 0;
    var iterator = operations.iterator();
    while (iterator.next()) |operation| {
        bits |= @as(u64, 1) << @intFromEnum(operation);
    }
    return bits;
}

/// A package as presented for installation.
pub const Package = struct {
    identity: Identity,
    manifest: Manifest,
    contents: []const u8,
    /// Absent when the package is unsigned.
    signature: ?[signature_bytes]u8,
};

/// A publisher this host will install from.
pub const Publisher = struct {
    name: []const u8,
    key: [public_key_bytes]u8,
};

/// What installation produced.
pub const Installation = struct {
    identity: Identity,
    version: Version,
    installed_at: time.Timestamp,
    /// True when installed under development mode without a signature.
    unsigned: bool,
};

/// Decides what may be installed.
///
/// Ownership: the installer owns its publisher table and its record of what is
/// installed. `deinit` releases both.
pub const Installer = struct {
    gpa: std.mem.Allocator,
    clock: time.Clock,
    /// Whether unsigned packages are accepted. Off unless deliberately set.
    development_mode: bool = false,
    publishers: std.StringHashMapUnmanaged([public_key_bytes]u8) = .empty,
    installed: std.StringHashMapUnmanaged(Installation) = .empty,

    pub fn init(gpa: std.mem.Allocator, clock: time.Clock) Installer {
        return .{ .gpa = gpa, .clock = clock };
    }

    pub fn deinit(installer: *Installer) void {
        installer.publishers.deinit(installer.gpa);
        var iterator = installer.installed.keyIterator();
        while (iterator.next()) |name| installer.gpa.free(name.*);
        installer.installed.deinit(installer.gpa);
        installer.* = undefined;
    }

    pub fn trustPublisher(installer: *Installer, publisher: Publisher) !void {
        try installer.publishers.put(installer.gpa, publisher.name, publisher.key);
    }

    pub fn revokePublisher(installer: *Installer, name: []const u8) void {
        _ = installer.publishers.remove(name);
    }

    /// Verifies a package without installing it.
    ///
    /// The order is deliberate: the manifest is bounded first, then the
    /// contents are confirmed to hash to the claimed identity, and only then is
    /// the signature checked. A package whose identity does not match its bytes
    /// is rejected before any key is consulted, because verifying a signature
    /// over the wrong contents proves nothing useful.
    pub fn verify(installer: *Installer, package: Package) Error!void {
        try package.manifest.validate();

        const computed: Identity = .ofContents(package.contents);
        if (!computed.eql(package.identity)) return error.IdentityMismatch;

        const signature = package.signature orelse {
            if (installer.development_mode) return;
            return error.UnsignedPackageRefused;
        };

        const key_bytes = installer.publishers.get(package.manifest.publisher) orelse
            return error.UnknownPublisher;
        const public_key = Ed25519.PublicKey.fromBytes(key_bytes) catch return error.IntegrityFailure;

        // The signature covers the manifest bound to the contents, not the
        // contents alone. Signing this digest, rather than the raw bytes, keeps
        // verification constant in the size of the package while still committing
        // to every declared capability, network destination, and version — so
        // none of them can be altered on a validly-signed package.
        const digest = package.manifest.signingDigest(package.contents);
        const parsed: Ed25519.Signature = .fromBytes(signature);
        parsed.verify(&digest, public_key) catch return error.IntegrityFailure;
    }

    /// Verifies and records a package as installed.
    ///
    /// An older version replacing a newer one is refused: a downgrade would
    /// reintroduce whatever the newer version fixed.
    pub fn install(installer: *Installer, package: Package) !Installation {
        try installer.verify(package);

        if (installer.installed.get(package.manifest.name)) |existing| {
            if (existing.version.isNewerThan(package.manifest.version)) {
                return error.RollbackRefused;
            }
        }

        const record: Installation = .{
            .identity = package.identity,
            .version = package.manifest.version,
            .installed_at = installer.clock.wall(),
            .unsigned = package.signature == null,
        };

        if (installer.installed.getPtr(package.manifest.name)) |existing| {
            existing.* = record;
        } else {
            const owned_name = try installer.gpa.dupe(u8, package.manifest.name);
            errdefer installer.gpa.free(owned_name);
            try installer.installed.put(installer.gpa, owned_name, record);
        }
        return record;
    }

    pub fn installedVersion(installer: Installer, name: []const u8) ?Installation {
        return installer.installed.get(name);
    }

    pub fn installedCount(installer: Installer) usize {
        return installer.installed.count();
    }
};

/// Signs a package: the manifest bound to its contents, so the signature commits
/// to every declared field and not merely to the bytes.
pub fn sign(key_pair: Ed25519.KeyPair, manifest: Manifest, contents: []const u8) ![signature_bytes]u8 {
    const digest = manifest.signingDigest(contents);
    const signature = try key_pair.sign(&digest, null);
    return signature.toBytes();
}

const Fixture = struct {
    manual: time.ManualClock,
    installer: Installer,
    key_pair: Ed25519.KeyPair,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(3);
        fixture.* = .{
            .manual = .init(.fromSeconds(1_000)),
            .installer = undefined,
            .key_pair = try .generateDeterministic(seed),
        };
        fixture.installer = .init(gpa, fixture.manual.clock());
        try fixture.installer.trustPublisher(.{
            .name = "reference publisher",
            .key = fixture.key_pair.public_key.toBytes(),
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.installer.deinit();
    }

    fn manifest(fixture: *Fixture) Manifest {
        _ = fixture;
        // Comptime so the declared-capabilities literal has static storage; a
        // runtime set would make `&.{...}` point at a stack temporary.
        const operations = comptime blk: {
            var set: capability_model.OperationSet = .initEmpty();
            set.insert(.read);
            break :blk set;
        };
        return .{
            .name = "calendar agent",
            .publisher = "reference publisher",
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .declared_capabilities = &.{
                .{
                    .resource_kind = "calendar",
                    .operations = operations,
                    .justification = "read scheduled events to prepare a summary",
                },
            },
        };
    }

    fn package(fixture: *Fixture, contents: []const u8) !Package {
        return fixture.signed(fixture.manifest(), contents);
    }

    /// Builds a package whose signature is valid for the given manifest and
    /// contents. Tests that need a variant manifest sign it here rather than
    /// mutating a package after signing, which the manifest-bound signature
    /// (correctly) rejects.
    fn signed(fixture: *Fixture, declared: Manifest, contents: []const u8) !Package {
        return .{
            .identity = .ofContents(contents),
            .manifest = declared,
            .contents = contents,
            .signature = try sign(fixture.key_pair, declared, contents),
        };
    }
};

test "identity is derived from contents and is deterministic" {
    const first: Identity = .ofContents("component bytes");
    const second: Identity = .ofContents("component bytes");
    const different: Identity = .ofContents("component byteS");

    try std.testing.expect(first.eql(second));
    try std.testing.expect(!first.eql(different));
}

test "a correctly signed package verifies and installs" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const package = try fixture.package("component bytes");
    const installation = try fixture.installer.install(package);

    try std.testing.expect(!installation.unsigned);
    try std.testing.expectEqual(@as(usize, 1), fixture.installer.installedCount());
}

test "an unsigned package is refused outside development mode" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var package = try fixture.package("component bytes");
    package.signature = null;

    try std.testing.expectError(error.UnsignedPackageRefused, fixture.installer.verify(package));

    // Development mode is a deliberate setting, not an inferred state.
    fixture.installer.development_mode = true;
    const installation = try fixture.installer.install(package);
    try std.testing.expect(installation.unsigned);
}

test "substituted contents are refused before any key is consulted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var package = try fixture.package("component bytes");
    // The signature and identity are genuine; the bytes are not.
    package.contents = "substituted bytes";

    try std.testing.expectError(error.IdentityMismatch, fixture.installer.verify(package));
}

test "a tampered signature is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var package = try fixture.package("component bytes");
    package.signature.?[0] ^= 0xff;

    try std.testing.expectError(error.IntegrityFailure, fixture.installer.verify(package));
}

test "a package signed by the wrong publisher is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const other_seed: [Ed25519.KeyPair.seed_length]u8 = @splat(5);
    const impostor: Ed25519.KeyPair = try .generateDeterministic(other_seed);

    var package = try fixture.package("component bytes");
    package.signature = try sign(impostor, package.manifest, package.contents);

    try std.testing.expectError(error.IntegrityFailure, fixture.installer.verify(package));
}

test "altering a declared capability on a validly-signed package is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var package = try fixture.package("component bytes");
    // The signature is valid for the manifest as signed; widen the declared
    // authority after signing. Because the signature commits to the manifest,
    // the altered package must fail to verify.
    var widened: capability_model.OperationSet = .initEmpty();
    widened.insert(.read);
    widened.insert(.write);
    var declared = [_]DeclaredCapability{.{
        .resource_kind = "calendar",
        .operations = widened,
        .justification = "read scheduled events to prepare a summary",
    }};
    package.manifest.declared_capabilities = &declared;

    try std.testing.expectError(error.IntegrityFailure, fixture.installer.verify(package));
}

test "altering the version on a validly-signed package is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var package = try fixture.package("component bytes");
    package.manifest.version = .{ .major = 9, .minor = 9, .patch = 9 };

    try std.testing.expectError(error.IntegrityFailure, fixture.installer.verify(package));
}

test "a package from an unknown publisher is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var package = try fixture.package("component bytes");
    package.manifest.publisher = "someone else";

    try std.testing.expectError(error.UnknownPublisher, fixture.installer.verify(package));
}

test "revoking a publisher stops the next installation from it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const package = try fixture.package("component bytes");
    _ = try fixture.installer.install(package);

    fixture.installer.revokePublisher("reference publisher");
    try std.testing.expectError(error.UnknownPublisher, fixture.installer.verify(package));
}

test "a downgrade is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var newer_manifest = fixture.manifest();
    newer_manifest.version = .{ .major = 2, .minor = 0, .patch = 0 };
    _ = try fixture.installer.install(try fixture.signed(newer_manifest, "version two bytes"));

    var older_manifest = fixture.manifest();
    older_manifest.version = .{ .major = 1, .minor = 0, .patch = 0 };
    const older = try fixture.signed(older_manifest, "version one bytes");

    try std.testing.expectError(error.RollbackRefused, fixture.installer.install(older));
    try std.testing.expectEqual(
        @as(u32, 2),
        fixture.installer.installedVersion("calendar agent").?.version.major,
    );
}

test "reinstalling the same version is permitted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const package = try fixture.package("component bytes");
    _ = try fixture.installer.install(package);
    _ = try fixture.installer.install(package);

    try std.testing.expectEqual(@as(usize, 1), fixture.installer.installedCount());
}

test "a malformed manifest is refused before anything acts on it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var package = try fixture.package("component bytes");

    package.manifest.name = "";
    try std.testing.expectError(error.InvalidManifest, fixture.installer.verify(package));

    package.manifest.name = "calendar agent";
    package.manifest.publisher = "";
    try std.testing.expectError(error.InvalidManifest, fixture.installer.verify(package));
}

test "a declared capability must say why it is wanted" {
    var operations: capability_model.OperationSet = .initEmpty();
    operations.insert(.read);

    const manifest: Manifest = .{
        .name = "agent",
        .publisher = "publisher",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .declared_capabilities = &.{
            .{ .resource_kind = "calendar", .operations = operations, .justification = "" },
        },
    };
    try std.testing.expectError(error.InvalidManifest, manifest.validate());
}

test "declaring a capability is not being granted it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var everything: capability_model.OperationSet = .initEmpty();
    for (std.enums.values(capability_model.Operation)) |operation| everything.insert(operation);

    const greedy_capabilities = [_]DeclaredCapability{.{
        .resource_kind = "mail",
        .operations = everything,
        .justification = "asks for everything",
    }};
    var greedy_manifest = fixture.manifest();
    greedy_manifest.declared_capabilities = &greedy_capabilities;
    const greedy = try fixture.signed(greedy_manifest, "component bytes");

    // Installation records the declaration. It confers nothing: the installer
    // returns no capability, and a grant is a separate policy decision.
    const installation = try fixture.installer.install(greedy);
    try std.testing.expectEqual(@TypeOf(installation), Installation);
    try std.testing.expect(@typeInfo(Installation) == .@"struct");
    inline for (@typeInfo(Installation).@"struct".fields) |field| {
        try std.testing.expect(!std.mem.eql(u8, field.name, "granted_capabilities"));
    }
}

test "an oversized manifest is refused" {
    var declared: [max_declared_capabilities + 1]DeclaredCapability = undefined;
    var operations: capability_model.OperationSet = .initEmpty();
    operations.insert(.read);
    for (&declared) |*entry| {
        entry.* = .{
            .resource_kind = "calendar",
            .operations = operations,
            .justification = "reason",
        };
    }

    const manifest: Manifest = .{
        .name = "agent",
        .publisher = "publisher",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .declared_capabilities = &declared,
    };
    try std.testing.expectError(error.InvalidManifest, manifest.validate());
}

test "version ordering is total and consistent" {
    const first: Version = .{ .major = 1, .minor = 2, .patch = 3 };
    const same: Version = .{ .major = 1, .minor = 2, .patch = 3 };
    const later_patch: Version = .{ .major = 1, .minor = 2, .patch = 4 };
    const later_minor: Version = .{ .major = 1, .minor = 3, .patch = 0 };
    const later_major: Version = .{ .major = 2, .minor = 0, .patch = 0 };

    try std.testing.expectEqual(std.math.Order.eq, first.order(same));
    try std.testing.expect(later_patch.isNewerThan(first));
    try std.testing.expect(later_minor.isNewerThan(later_patch));
    try std.testing.expect(later_major.isNewerThan(later_minor));
    try std.testing.expect(!first.isNewerThan(same));
}

test "required and optional capabilities are distinguished" {
    var operations: capability_model.OperationSet = .initEmpty();
    operations.insert(.read);

    const manifest: Manifest = .{
        .name = "agent",
        .publisher = "publisher",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .declared_capabilities = &.{
            .{ .resource_kind = "calendar", .operations = operations, .justification = "core" },
            .{
                .resource_kind = "route",
                .operations = operations,
                .justification = "enhancement",
                .optional = true,
            },
        },
    };
    try manifest.validate();
    try std.testing.expectEqual(@as(usize, 1), manifest.requiredCount());
}
