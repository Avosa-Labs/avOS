//! The agent manifest: the signed contract a human accepts and the trusted core enforces.
//!
//! Every agent declares what it may touch. This turns that declaration into a signed artifact: the
//! capabilities the agent requests (each with the approval class the operation must clear), the
//! namespaces it may read, write, and delete within, the namespaces it is willing to expose, its
//! delegation policy, its budgets, and its data-privacy class. The manifest is content-hashed over a
//! canonical, deterministic serialization, and endorsed — the endorsing root signs that hash — so the
//! contract is verifiable at any time and any later drift is detectable.
//!
//! Two rules the core turns into behaviour: acceptance is the grant (a capability absent from the
//! accepted manifest simply has no grant, so acting outside the manifest is denied by construction),
//! and widening is re-consent (a manifest that requests more authority than the one already accepted is
//! a new contract requiring fresh human acceptance; narrowing applies without it). The signature scheme
//! is the vetted Ed25519 already used across the control plane — no invented primitive.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const principal = @import("../principal/principal.zig");
const time = @import("../time/time.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;
pub const digest_bytes = Sha256.digest_length;

pub const Error = error{ EndorsementInvalid, IssuerMismatch };

/// The approval class an operation must clear. Ordered by how much it constrains the agent: a silent
/// read constrains least, a human-only action most. The order is what lets widening be detected — an
/// operation moving to a less-constraining class is more authority.
pub const ActionClass = enum(u8) {
    silent = 0,
    notify = 1,
    hold = 2,
    human_only = 3,

    /// True when `self` constrains the agent less than `other` — i.e. moving from `other` to `self`
    /// grants more freedom, which is a widening.
    pub fn loosensFrom(self: ActionClass, other: ActionClass) bool {
        return @intFromEnum(self) < @intFromEnum(other);
    }
};

/// A capability the agent requests, and the approval class its operations run under.
pub const CapabilityRequest = struct {
    name: []const u8,
    action_class: ActionClass,
};

/// A namespace the agent may reach, and the reach it holds there. Delete is called out explicitly
/// because it is the reach a human most needs to see and consent to.
pub const NamespaceGrant = struct {
    namespace: []const u8,
    read: bool = false,
    write: bool = false,
    delete: bool = false,

    /// True when `self` reaches into the namespace beyond what `other` allows.
    fn exceeds(self: NamespaceGrant, other: NamespaceGrant) bool {
        return (self.read and !other.read) or (self.write and !other.write) or (self.delete and !other.delete);
    }
};

/// The resources the agent may spend. A higher ceiling on any of them is more authority.
pub const Budgets = struct {
    cpu_ms: u64 = 0,
    memory_bytes: u64 = 0,
    model_tokens: u64 = 0,
    monetary_cents: u64 = 0,
    interruptions: u32 = 0,
};

/// How far data the agent touches may travel. Ordered from most to least contained; a class that lets
/// data travel further than the accepted one is a widening.
pub const DataClass = enum(u8) {
    never_leaves_device = 0,
    sensitive = 1,
    personal = 2,
    public = 3,
};

pub const DelegationPolicy = struct {
    may_delegate: bool = false,
    max_depth: u8 = 0,
};

/// The manifest itself. The slices are borrowed — the caller owns their storage for the manifest's
/// lifetime — so the manifest carries no allocation of its own.
pub const Manifest = struct {
    /// The agent this manifest governs, and the root that endorses it (an account for an owner's own
    /// agent; a device co-endorses an embodied one).
    subject: identity.PrincipalId,
    issuer: identity.PrincipalId,
    kind: principal.Kind,
    /// The agent's own public identity material — the key its own signatures are verified against.
    public_key: [public_key_bytes]u8,
    /// When the manifest ceases to be valid; an agent past this is inert.
    expires_at: ?time.Timestamp,
    capabilities: []const CapabilityRequest,
    namespaces_requested: []const NamespaceGrant,
    namespaces_offered: []const NamespaceGrant,
    delegation: DelegationPolicy,
    budgets: Budgets,
    data_class: DataClass,

    /// The content hash over a canonical serialization: a fixed field order, ints little-endian, each
    /// string length-prefixed so no two distinct manifests collide. Any change to any field changes it.
    pub fn hash(self: Manifest) [digest_bytes]u8 {
        var hasher = Sha256.init(.{});
        hasher.update("agent.manifest.v1");
        hashInt(&hasher, u128, self.subject.value);
        hashInt(&hasher, u128, self.issuer.value);
        hashInt(&hasher, u8, @intFromEnum(self.kind));
        hasher.update(&self.public_key);
        hashInt(&hasher, u8, @intFromBool(self.expires_at != null));
        hashInt(&hasher, i64, if (self.expires_at) |e| e.nanoseconds else 0);

        hashInt(&hasher, u32, @intCast(self.capabilities.len));
        for (self.capabilities) |request| {
            hashField(&hasher, request.name);
            hashInt(&hasher, u8, @intFromEnum(request.action_class));
        }
        hashNamespaces(&hasher, self.namespaces_requested);
        hashNamespaces(&hasher, self.namespaces_offered);

        hashInt(&hasher, u8, @intFromBool(self.delegation.may_delegate));
        hashInt(&hasher, u8, self.delegation.max_depth);
        hashInt(&hasher, u64, self.budgets.cpu_ms);
        hashInt(&hasher, u64, self.budgets.memory_bytes);
        hashInt(&hasher, u64, self.budgets.model_tokens);
        hashInt(&hasher, u64, self.budgets.monetary_cents);
        hashInt(&hasher, u32, self.budgets.interruptions);
        hashInt(&hasher, u8, @intFromEnum(self.data_class));

        var digest: [digest_bytes]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }

    /// The approval class the manifest grants for a capability, or null when the capability is not in
    /// the manifest at all — deny by default. This is the check that makes acting outside the accepted
    /// manifest impossible: an operation whose capability isn't declared simply has no grant.
    pub fn classOf(self: Manifest, capability_name: []const u8) ?ActionClass {
        for (self.capabilities) |request| {
            if (std.mem.eql(u8, request.name, capability_name)) return request.action_class;
        }
        return null;
    }

    /// Whether the manifest permits the capability at all (it is declared).
    pub fn permits(self: Manifest, capability_name: []const u8) bool {
        return self.classOf(capability_name) != null;
    }

    /// Whether the manifest is still in force at `now`. An expired manifest's agent is inert.
    pub fn active(self: Manifest, now: time.Timestamp) bool {
        if (self.expires_at) |expiry| return !now.isAfter(expiry);
        return true;
    }

    /// Whether `self` requests more authority than `accepted` — a wider capability set or looser class,
    /// deeper namespace reach, newly-offered namespaces, higher budgets, deeper delegation, or a
    /// data class that lets data travel further. Widening requires fresh human acceptance; a manifest
    /// that only narrows does not. The comparison is one pass over each side's declarations.
    pub fn widensBeyond(self: Manifest, accepted: Manifest) bool {
        for (self.capabilities) |request| {
            const prior = accepted.classOf(request.name) orelse return true; // a capability not accepted before
            if (request.action_class.loosensFrom(prior)) return true; // same capability, looser class
        }
        if (namespacesExceed(self.namespaces_requested, accepted.namespaces_requested)) return true;
        if (namespacesExceed(self.namespaces_offered, accepted.namespaces_offered)) return true;
        if (self.budgets.cpu_ms > accepted.budgets.cpu_ms) return true;
        if (self.budgets.memory_bytes > accepted.budgets.memory_bytes) return true;
        if (self.budgets.model_tokens > accepted.budgets.model_tokens) return true;
        if (self.budgets.monetary_cents > accepted.budgets.monetary_cents) return true;
        if (self.budgets.interruptions > accepted.budgets.interruptions) return true;
        if (self.delegation.may_delegate and !accepted.delegation.may_delegate) return true;
        if (self.delegation.max_depth > accepted.delegation.max_depth) return true;
        if (@intFromEnum(self.data_class) > @intFromEnum(accepted.data_class)) return true; // travels further
        return false;
    }
};

/// The endorsement that binds an agent's manifest to the root that vouches for it: the issuer signs the
/// manifest hash with its own key. Verifying the agent means verifying this back to a trust root the
/// verifier accepts.
pub const Endorsement = struct {
    /// The root principal whose key signed — the endorser.
    issuer: identity.PrincipalId,
    signature: [signature_bytes]u8,
};

/// Endorses a manifest: the issuer signs its content hash. The manifest's `issuer` must be the endorser
/// — an agent cannot be endorsed by anyone other than the root its manifest names.
pub fn endorse(issuer_key: Ed25519.KeyPair, issuer: identity.PrincipalId, manifest: Manifest) Error!Endorsement {
    if (!manifest.issuer.eql(issuer)) return Error.IssuerMismatch;
    const digest = manifest.hash();
    const signature = issuer_key.sign(&digest, null) catch return Error.EndorsementInvalid;
    return .{ .issuer = issuer, .signature = signature.toBytes() };
}

/// A signer that never surfaces its private key: it takes a digest and returns the signature over it, or
/// null when it declines. This is the seam a keystore over a secure element implements — the issuer's key
/// stays in custody and only signatures leave it — so endorsing an agent's manifest never means handing
/// the account's private key to the provisioning path.
pub const Signer = struct {
    context: *anyopaque,
    signFn: *const fn (context: *anyopaque, digest: [digest_bytes]u8) ?[signature_bytes]u8,

    pub fn sign(signer: Signer, digest: [digest_bytes]u8) ?[signature_bytes]u8 {
        return signer.signFn(signer.context, digest);
    }
};

/// Endorses a manifest through a custody-held signer rather than a bare key pair: the issuer's key stays
/// inside the keystore and only the signature crosses out. Otherwise identical to `endorse` — the issuer
/// must be the manifest's named endorser, and a signer that declines fails closed.
pub fn endorseWith(signer: Signer, issuer: identity.PrincipalId, manifest: Manifest) Error!Endorsement {
    if (!manifest.issuer.eql(issuer)) return Error.IssuerMismatch;
    const digest = manifest.hash();
    const signature = signer.sign(digest) orelse return Error.EndorsementInvalid;
    return .{ .issuer = issuer, .signature = signature };
}

/// Verifies an endorsement: the signature is the issuer's over this exact manifest. A tampered manifest,
/// a wrong endorser, or a broken signature all fail closed — the agent is inert until it verifies.
pub fn verify(manifest: Manifest, issuer_public_key: [public_key_bytes]u8, endorsement: Endorsement) Error!void {
    if (!endorsement.issuer.eql(manifest.issuer)) return Error.IssuerMismatch;
    const digest = manifest.hash();
    const key = Ed25519.PublicKey.fromBytes(issuer_public_key) catch return Error.EndorsementInvalid;
    const signature: Ed25519.Signature = .fromBytes(endorsement.signature);
    signature.verify(&digest, key) catch return Error.EndorsementInvalid;
}

fn namespacesExceed(candidate: []const NamespaceGrant, accepted: []const NamespaceGrant) bool {
    for (candidate) |grant| {
        const prior = findNamespace(accepted, grant.namespace) orelse {
            if (grant.read or grant.write or grant.delete) return true; // a namespace not reachable before
            continue;
        };
        if (grant.exceeds(prior)) return true;
    }
    return false;
}

fn findNamespace(grants: []const NamespaceGrant, name: []const u8) ?NamespaceGrant {
    for (grants) |grant| {
        if (std.mem.eql(u8, grant.namespace, name)) return grant;
    }
    return null;
}

fn hashNamespaces(hasher: *Sha256, grants: []const NamespaceGrant) void {
    hashInt(hasher, u32, @intCast(grants.len));
    for (grants) |grant| {
        hashField(hasher, grant.namespace);
        hashInt(hasher, u8, @intFromBool(grant.read));
        hashInt(hasher, u8, @intFromBool(grant.write));
        hashInt(hasher, u8, @intFromBool(grant.delete));
    }
}

fn hashField(hasher: *Sha256, field: []const u8) void {
    hashInt(hasher, u32, @intCast(field.len));
    hasher.update(field);
}

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

// --- Tests ---

const testing = std.testing;

fn sampleManifest(subject: u128, issuer: u128, key: [public_key_bytes]u8) Manifest {
    const caps = &[_]CapabilityRequest{
        .{ .name = "calendar.read", .action_class = .silent },
        .{ .name = "calendar.commit", .action_class = .hold },
    };
    const spaces = &[_]NamespaceGrant{
        .{ .namespace = "calendar/personal", .read = true, .write = true },
    };
    return .{
        .subject = .{ .value = subject },
        .issuer = .{ .value = issuer },
        .kind = .agent,
        .public_key = key,
        .expires_at = .fromSeconds(10_000),
        .capabilities = caps,
        .namespaces_requested = spaces,
        .namespaces_offered = &.{},
        .delegation = .{ .may_delegate = true, .max_depth = 1 },
        .budgets = .{ .cpu_ms = 1000, .model_tokens = 4096, .monetary_cents = 0 },
        .data_class = .personal,
    };
}

test "an endorsement verifies against the issuer's key and this exact manifest" {
    const issuer_key = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const manifest = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());

    const endorsement = try endorse(issuer_key, .{ .value = 0x1 }, manifest);
    try verify(manifest, issuer_key.public_key.toBytes(), endorsement);
}

test "a custody-held signer endorses without ever surfacing its key" {
    const issuer_key = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const manifest = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());

    // A signer that holds the key behind a closure, mirroring a keystore over a secure element.
    const Custody = struct {
        key: Ed25519.KeyPair,
        fn signFor(context: *anyopaque, digest: [digest_bytes]u8) ?[signature_bytes]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const signature = self.key.sign(&digest, null) catch return null;
            return signature.toBytes();
        }
    };
    var custody = Custody{ .key = issuer_key };
    const signer: Signer = .{ .context = &custody, .signFn = Custody.signFor };

    const endorsement = try endorseWith(signer, .{ .value = 0x1 }, manifest);
    try verify(manifest, issuer_key.public_key.toBytes(), endorsement);

    // The seam still enforces that only the manifest's named issuer may endorse it.
    try testing.expectError(Error.IssuerMismatch, endorseWith(signer, .{ .value = 0x2 }, manifest));
}

test "a tampered manifest fails verification, so drift disables the agent" {
    const issuer_key = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    var manifest = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    const endorsement = try endorse(issuer_key, .{ .value = 0x1 }, manifest);

    // Widen the manifest after it was signed: the same endorsement no longer verifies.
    manifest.capabilities = &[_]CapabilityRequest{
        .{ .name = "calendar.read", .action_class = .silent },
        .{ .name = "calendar.commit", .action_class = .silent }, // was .hold
    };
    try testing.expectError(Error.EndorsementInvalid, verify(manifest, issuer_key.public_key.toBytes(), endorsement));
}

test "a wrong endorser key fails verification" {
    const issuer_key = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const impostor = try Ed25519.KeyPair.generateDeterministic(@splat(8));
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const manifest = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    const endorsement = try endorse(issuer_key, .{ .value = 0x1 }, manifest);
    try testing.expectError(Error.EndorsementInvalid, verify(manifest, impostor.public_key.toBytes(), endorsement));
}

test "endorsing with a key whose principal is not the manifest issuer is refused" {
    const issuer_key = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const manifest = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    try testing.expectError(Error.IssuerMismatch, endorse(issuer_key, .{ .value = 0x2 }, manifest));
}

test "a capability absent from the manifest has no grant — deny by default" {
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const manifest = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    try testing.expectEqual(ActionClass.hold, manifest.classOf("calendar.commit").?);
    try testing.expect(manifest.permits("calendar.read"));
    try testing.expect(!manifest.permits("files.delete")); // never declared
    try testing.expect(manifest.classOf("files.delete") == null);
}

test "an expired manifest is inert" {
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const manifest = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    try testing.expect(manifest.active(.fromSeconds(9_999)));
    try testing.expect(!manifest.active(.fromSeconds(10_001)));
}

test "widening requires re-consent; narrowing does not" {
    const agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const accepted = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());

    // Identical manifest: no widening.
    try testing.expect(!sampleManifest(0xA, 0x1, agent_key.public_key.toBytes()).widensBeyond(accepted));

    // A new capability widens.
    var wider = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    wider.capabilities = &[_]CapabilityRequest{
        .{ .name = "calendar.read", .action_class = .silent },
        .{ .name = "calendar.commit", .action_class = .hold },
        .{ .name = "files.delete", .action_class = .hold },
    };
    try testing.expect(wider.widensBeyond(accepted));

    // A looser class on an existing capability widens.
    var looser = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    looser.capabilities = &[_]CapabilityRequest{
        .{ .name = "calendar.read", .action_class = .silent },
        .{ .name = "calendar.commit", .action_class = .notify }, // was hold
    };
    try testing.expect(looser.widensBeyond(accepted));

    // Deeper namespace reach (delete) widens.
    var deeper = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    deeper.namespaces_requested = &[_]NamespaceGrant{
        .{ .namespace = "calendar/personal", .read = true, .write = true, .delete = true },
    };
    try testing.expect(deeper.widensBeyond(accepted));

    // A higher budget widens.
    var richer = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    richer.budgets.monetary_cents = 500;
    try testing.expect(richer.widensBeyond(accepted));

    // Data allowed to travel further widens.
    var leakier = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    leakier.data_class = .public;
    try testing.expect(leakier.widensBeyond(accepted));

    // Strictly narrowing: fewer capabilities, tighter class — not a widening.
    var narrower = sampleManifest(0xA, 0x1, agent_key.public_key.toBytes());
    narrower.capabilities = &[_]CapabilityRequest{
        .{ .name = "calendar.read", .action_class = .notify }, // tighter than silent
    };
    narrower.budgets = .{};
    narrower.data_class = .never_leaves_device;
    narrower.delegation = .{};
    try testing.expect(!narrower.widensBeyond(accepted));
}
