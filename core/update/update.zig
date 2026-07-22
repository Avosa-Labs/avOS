//! System updates: atomic, verified, and reversible.
//!
//! An update either takes effect completely or not at all. There is no state in
//! which the system is running half of one version and half of another, because
//! the switch is a single change to which slot boots — everything before that is
//! preparation that can be abandoned.
//!
//! A failed update returns to a bootable prior state. That is the property that
//! makes updating safe to do at all: a device that can be left unbootable by an
//! interrupted update is a device nobody should update.
//!
//! Anti-rollback is separate from rollback. Rolling back to the slot that was
//! working is recovery; installing an older image than the device has already
//! run is an attack, because it reintroduces whatever the newer one fixed.

const std = @import("std");
const core_time = @import("../time/time.zig");
const package_model = @import("../package/package.zig");
const identity = @import("../identity/identity.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;
pub const digest_bytes = Sha256.digest_length;

pub const Error = error{
    /// The image is not signed by a key this device accepts.
    IntegrityFailure,
    /// The image is older than one this device has already run.
    RollbackRefused,
    /// The image is not built for this device.
    IncompatibleImage,
    /// No prior slot is bootable, so there is nothing to fall back to.
    NoBootableFallback,
    /// The update is not at a stage where this is permitted.
    WrongStage,
    /// The image would not fit the slot it is staged into.
    ImageTooLarge,
    /// Every slot is in use by something that must not be overwritten.
    NoSlotAvailable,
};

/// Which slot an image occupies.
///
/// Two slots, so the running system is never the one being written. Writing
/// over the running system is what makes an interrupted update unrecoverable.
pub const Slot = enum {
    primary,
    secondary,

    pub fn other(slot: Slot) Slot {
        return switch (slot) {
            .primary => .secondary,
            .secondary => .primary,
        };
    }
};

/// How far an update has progressed.
///
/// Explicit stages, because "partly installed" is the state that must never be
/// bootable. Only `committed` changes which slot boots.
pub const Stage = enum {
    /// Nothing in progress.
    idle,
    /// The image is being written to the inactive slot.
    staging,
    /// Written and verified, not yet trusted to boot.
    staged,
    /// Selected for the next boot, but not yet proven to work.
    pending_verification,
    /// Booted successfully and confirmed.
    committed,
    /// Abandoned; the previous slot still boots.
    rolled_back,

    /// Whether an update at this stage has changed what boots.
    pub fn hasChangedBootSelection(stage: Stage) bool {
        return switch (stage) {
            .pending_verification, .committed => true,
            .idle, .staging, .staged, .rolled_back => false,
        };
    }

    /// Whether another update may begin from this stage.
    ///
    /// Only from a stage where none is in flight. A committed update is
    /// finished, so the next one starts from there just as it would from a
    /// device that has never updated; without this a device could be updated
    /// exactly once.
    pub fn permitsFurtherUpdate(stage: Stage) bool {
        return switch (stage) {
            .idle, .committed, .rolled_back => true,
            .staging, .staged, .pending_verification => false,
        };
    }
};

/// A system version. Ordered, because anti-rollback depends on comparing them.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Increases whenever a release fixes something that must not be
    /// reintroduced. Distinct from the version so a security fix can raise the
    /// floor without forcing a major version.
    security_generation: u32,

    pub fn order(version: Version, other: Version) std.math.Order {
        if (version.major != other.major) return std.math.order(version.major, other.major);
        if (version.minor != other.minor) return std.math.order(version.minor, other.minor);
        return std.math.order(version.patch, other.patch);
    }

    pub fn isNewerThan(version: Version, other: Version) bool {
        return version.order(other) == .gt;
    }
};

/// An image offered to the device.
pub const Image = struct {
    version: Version,
    /// Content-derived identity, as with any package.
    digest: [digest_bytes]u8,
    size_bytes: usize,
    /// Which hardware this image is built for.
    device_class: []const u8,
    signature: [signature_bytes]u8,

    pub fn ofContents(
        contents: []const u8,
        version: Version,
        device_class: []const u8,
        signature: [signature_bytes]u8,
    ) Image {
        var digest: [digest_bytes]u8 = undefined;
        Sha256.hash(contents, &digest, .{});
        return .{
            .version = version,
            .digest = digest,
            .size_bytes = contents.len,
            .device_class = device_class,
            .signature = signature,
        };
    }
};

/// What a slot currently holds.
pub const SlotState = struct {
    /// Null when the slot has never held a complete image.
    version: ?Version = null,
    digest: [digest_bytes]u8 = @splat(0),
    /// Whether this slot is known to boot. A slot being written is not.
    bootable: bool = false,
    /// Boot attempts made without the system confirming it started correctly.
    /// A slot that keeps failing is abandoned rather than retried forever.
    failed_boots: u8 = 0,
};

/// How many times a pending image may fail to boot before it is abandoned.
pub const max_boot_attempts: u8 = 3;

/// Largest image a slot holds.
pub const max_image_bytes: usize = 4 * 1024 * 1024 * 1024;

/// The device's update state.
///
/// Ownership: this structure holds no allocations. It is the durable record of
/// which slot boots and what each holds, and is written through the journal
/// like any other state transition.
pub const Updater = struct {
    clock: core_time.Clock,
    /// The key releases must be signed with.
    release_key: [public_key_bytes]u8,
    /// Which hardware this device is.
    device_class: []const u8,
    /// The slot currently running.
    active: Slot,
    slots: [2]SlotState,
    current_stage: Stage = .idle,
    /// The slot being staged into, while an update is in progress.
    staging_into: ?Slot = null,
    /// The highest security generation this device has ever run.
    ///
    /// Never decreases. Installing an image below it reintroduces something a
    /// newer release fixed, which is the definition of a rollback attack.
    security_floor: u32 = 0,

    pub fn init(
        clock: core_time.Clock,
        release_key: [public_key_bytes]u8,
        device_class: []const u8,
        initial: Version,
        initial_digest: [digest_bytes]u8,
    ) Updater {
        var updater: Updater = .{
            .clock = clock,
            .release_key = release_key,
            .device_class = device_class,
            .active = .primary,
            .slots = .{ .{}, .{} },
            .security_floor = initial.security_generation,
        };
        updater.slots[@intFromEnum(Slot.primary)] = .{
            .version = initial,
            .digest = initial_digest,
            .bootable = true,
        };
        return updater;
    }

    /// Which stage the update is in.
    pub fn currentStage(updater: Updater) Stage {
        return updater.current_stage;
    }

    pub fn slotState(updater: Updater, slot: Slot) SlotState {
        return updater.slots[@intFromEnum(slot)];
    }

    pub fn runningVersion(updater: Updater) ?Version {
        return updater.slotState(updater.active).version;
    }

    /// Checks an image without staging it.
    ///
    /// The order is deliberate: compatibility and anti-rollback are decided
    /// before the signature, because a device should refuse an image it must
    /// not run whether or not the signature is valid, and checking the cheap
    /// conditions first means a flood of images costs less to reject.
    pub fn verify(updater: Updater, image: Image, contents: []const u8) Error!void {
        if (image.size_bytes > max_image_bytes) return error.ImageTooLarge;
        if (!std.mem.eql(u8, image.device_class, updater.device_class)) {
            return error.IncompatibleImage;
        }

        if (image.version.security_generation < updater.security_floor) {
            return error.RollbackRefused;
        }
        if (updater.runningVersion()) |running| {
            if (running.isNewerThan(image.version)) return error.RollbackRefused;
        }

        var computed: [digest_bytes]u8 = undefined;
        Sha256.hash(contents, &computed, .{});
        if (!std.crypto.timing_safe.eql([digest_bytes]u8, computed, image.digest)) {
            return error.IntegrityFailure;
        }

        const key = Ed25519.PublicKey.fromBytes(updater.release_key) catch
            return error.IntegrityFailure;
        const signature: Ed25519.Signature = .fromBytes(image.signature);
        signature.verify(&image.digest, key) catch return error.IntegrityFailure;
    }

    /// Begins writing an image into the inactive slot.
    ///
    /// Never the active slot. Writing over the running system is what makes an
    /// interrupted update unrecoverable.
    pub fn stage(updater: *Updater, image: Image, contents: []const u8) Error!Slot {
        if (!updater.current_stage.permitsFurtherUpdate()) return error.WrongStage;
        try updater.verify(image, contents);

        const target = updater.active.other();
        updater.staging_into = target;
        updater.current_stage = .staging;

        // The slot stops being bootable the moment it starts being written: a
        // half-written slot must never be selected, even by a crash.
        updater.slots[@intFromEnum(target)] = .{
            .version = null,
            .digest = image.digest,
            .bootable = false,
        };
        return target;
    }

    /// Completes a staging write.
    ///
    /// The slot becomes bootable only here, after the whole image is present
    /// and verified. A crash before this leaves the slot unbootable, which is
    /// the correct state for a slot holding part of an image.
    pub fn finishStaging(updater: *Updater, image: Image, contents: []const u8) Error!void {
        if (updater.current_stage != .staging) return error.WrongStage;
        try updater.verify(image, contents);

        const target = updater.staging_into orelse return error.WrongStage;
        updater.slots[@intFromEnum(target)] = .{
            .version = image.version,
            .digest = image.digest,
            .bootable = true,
            .failed_boots = 0,
        };
        updater.current_stage = .staged;
    }

    /// Selects the staged slot for the next boot.
    ///
    /// This is the atomic point. Everything before it is preparation that can
    /// be abandoned; after it the device will try the new image, and if that
    /// fails it returns to the slot that was working.
    pub fn selectForNextBoot(updater: *Updater) Error!void {
        if (updater.current_stage != .staged) return error.WrongStage;
        const target = updater.staging_into orelse return error.WrongStage;
        if (!updater.slots[@intFromEnum(target)].bootable) return error.WrongStage;

        // There must be something to fall back to before the switch is made.
        if (!updater.slots[@intFromEnum(updater.active)].bootable) {
            return error.NoBootableFallback;
        }

        updater.current_stage = .pending_verification;
    }

    /// Which slot the device should boot next.
    pub fn nextBootSlot(updater: Updater) Slot {
        if (updater.current_stage == .pending_verification) {
            if (updater.staging_into) |target| return target;
        }
        return updater.active;
    }

    /// Records that the pending image booted and started correctly.
    ///
    /// Until this happens the update is not committed, so a device that boots
    /// the new image but fails to reach a working state still returns to the
    /// old one.
    pub fn confirmBoot(updater: *Updater) Error!void {
        if (updater.current_stage != .pending_verification) return error.WrongStage;
        const target = updater.staging_into orelse return error.WrongStage;

        updater.active = target;
        updater.current_stage = .committed;
        updater.staging_into = null;
        updater.slots[@intFromEnum(target)].failed_boots = 0;

        // The floor rises only on a confirmed boot. Raising it earlier would
        // let a failed update strand the device below its own floor.
        if (updater.slots[@intFromEnum(target)].version) |version| {
            updater.security_floor = @max(updater.security_floor, version.security_generation);
        }
    }

    /// Records that the pending image failed to boot or to start correctly.
    ///
    /// After enough attempts the update is abandoned and the previous slot
    /// boots again. Retrying forever would leave a device looping on an image
    /// that does not work.
    pub fn reportBootFailure(updater: *Updater) Error!void {
        if (updater.current_stage != .pending_verification) return error.WrongStage;
        const target = updater.staging_into orelse return error.WrongStage;

        const state = &updater.slots[@intFromEnum(target)];
        state.failed_boots +|= 1;

        if (state.failed_boots >= max_boot_attempts) {
            state.bootable = false;
            updater.current_stage = .rolled_back;
            updater.staging_into = null;
        }
    }

    /// Abandons an update deliberately.
    pub fn rollBack(updater: *Updater) Error!void {
        switch (updater.current_stage) {
            .staging, .staged, .pending_verification => {},
            else => return error.WrongStage,
        }
        if (updater.staging_into) |target| {
            updater.slots[@intFromEnum(target)].bootable = false;
        }
        if (!updater.slots[@intFromEnum(updater.active)].bootable) {
            return error.NoBootableFallback;
        }
        updater.current_stage = .rolled_back;
        updater.staging_into = null;
    }

    /// Whether the device can boot at all.
    ///
    /// The invariant every path must preserve: at least one slot boots, at
    /// every moment, including part-way through an update.
    pub fn hasBootableSlot(updater: Updater) bool {
        return updater.slots[0].bootable or updater.slots[1].bootable;
    }
};

const reference_device = "reference-handset";

const Fixture = struct {
    manual: core_time.ManualClock,
    key_pair: Ed25519.KeyPair,
    updater: Updater,

    fn init(fixture: *Fixture) !void {
        const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(23);
        fixture.* = .{
            .manual = .init(.fromSeconds(1_000)),
            .key_pair = try .generateDeterministic(seed),
            .updater = undefined,
        };

        var initial_digest: [digest_bytes]u8 = undefined;
        Sha256.hash("the shipped image", &initial_digest, .{});

        fixture.updater = .init(
            fixture.manual.clock(),
            fixture.key_pair.public_key.toBytes(),
            reference_device,
            .{ .major = 1, .minor = 0, .patch = 0, .security_generation = 1 },
            initial_digest,
        );
    }

    fn sign(fixture: *Fixture, digest: [digest_bytes]u8) ![signature_bytes]u8 {
        const signature = try fixture.key_pair.sign(&digest, null);
        return signature.toBytes();
    }

    fn image(fixture: *Fixture, contents: []const u8, version: Version) !Image {
        var digest: [digest_bytes]u8 = undefined;
        Sha256.hash(contents, &digest, .{});
        return Image.ofContents(contents, version, reference_device, try fixture.sign(digest));
    }

    /// A complete, successful update.
    fn applyUpdate(fixture: *Fixture, contents: []const u8, version: Version) !void {
        const candidate = try fixture.image(contents, version);
        _ = try fixture.updater.stage(candidate, contents);
        try fixture.updater.finishStaging(candidate, contents);
        try fixture.updater.selectForNextBoot();
        try fixture.updater.confirmBoot();
    }
};

const next_version: Version = .{ .major = 1, .minor = 1, .patch = 0, .security_generation = 1 };

test "a signed, compatible, newer image installs and commits" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    try fixture.applyUpdate("the next image", next_version);

    try std.testing.expectEqual(Slot.secondary, fixture.updater.active);
    try std.testing.expectEqual(Stage.committed, fixture.updater.current_stage);
    try std.testing.expectEqual(@as(u32, 1), fixture.updater.runningVersion().?.minor);
}

test "an update is never written over the running slot" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "the next image";
    const candidate = try fixture.image(contents, next_version);
    const target = try fixture.updater.stage(candidate, contents);

    // Writing over the running system is what makes an interrupted update
    // unrecoverable.
    try std.testing.expect(target != fixture.updater.active);
    try std.testing.expect(fixture.updater.slotState(fixture.updater.active).bootable);
}

test "a slot being written is not bootable" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "the next image";
    const candidate = try fixture.image(contents, next_version);
    const target = try fixture.updater.stage(candidate, contents);

    // A crash here must not leave a half-written slot selectable.
    try std.testing.expect(!fixture.updater.slotState(target).bootable);
    try std.testing.expectEqual(fixture.updater.active, fixture.updater.nextBootSlot());
    try std.testing.expect(fixture.updater.hasBootableSlot());
}

test "an image that fails to boot returns the device to the working slot" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "an image that does not start";
    const candidate = try fixture.image(contents, next_version);
    _ = try fixture.updater.stage(candidate, contents);
    try fixture.updater.finishStaging(candidate, contents);
    try fixture.updater.selectForNextBoot();

    // It is selected but not committed.
    try std.testing.expectEqual(Slot.secondary, fixture.updater.nextBootSlot());
    try std.testing.expectEqual(Slot.primary, fixture.updater.active);

    for (0..max_boot_attempts) |_| {
        try fixture.updater.reportBootFailure();
    }

    // Abandoned, and the slot that was working still boots.
    try std.testing.expectEqual(Stage.rolled_back, fixture.updater.current_stage);
    try std.testing.expectEqual(Slot.primary, fixture.updater.active);
    try std.testing.expectEqual(Slot.primary, fixture.updater.nextBootSlot());
    try std.testing.expect(fixture.updater.hasBootableSlot());
}

test "a failing image is abandoned rather than retried forever" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "an image that does not start";
    const candidate = try fixture.image(contents, next_version);
    _ = try fixture.updater.stage(candidate, contents);
    try fixture.updater.finishStaging(candidate, contents);
    try fixture.updater.selectForNextBoot();

    for (0..max_boot_attempts) |_| try fixture.updater.reportBootFailure();

    // Further reports are refused: the update is over.
    try std.testing.expectError(error.WrongStage, fixture.updater.reportBootFailure());
}

test "an unsigned or wrongly signed image is refused" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "an image from somewhere else";
    var digest: [digest_bytes]u8 = undefined;
    Sha256.hash(contents, &digest, .{});

    const impostor_seed: [Ed25519.KeyPair.seed_length]u8 = @splat(29);
    const impostor: Ed25519.KeyPair = try .generateDeterministic(impostor_seed);
    const forged = (try impostor.sign(&digest, null)).toBytes();

    const candidate: Image = .ofContents(contents, next_version, reference_device, forged);
    try std.testing.expectError(
        error.IntegrityFailure,
        fixture.updater.verify(candidate, contents),
    );
}

test "substituted contents are refused even with a genuine signature" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const genuine = "the next image";
    var candidate = try fixture.image(genuine, next_version);

    try std.testing.expectError(
        error.IntegrityFailure,
        fixture.updater.verify(candidate, "substituted contents"),
    );

    // And tampering with the signature is caught too.
    candidate.signature[0] ^= 0xff;
    try std.testing.expectError(
        error.IntegrityFailure,
        fixture.updater.verify(candidate, genuine),
    );
}

test "an image for different hardware is refused" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "an image for another device";
    var digest: [digest_bytes]u8 = undefined;
    Sha256.hash(contents, &digest, .{});

    const candidate: Image = .ofContents(
        contents,
        next_version,
        "a-different-device",
        try fixture.sign(digest),
    );
    try std.testing.expectError(
        error.IncompatibleImage,
        fixture.updater.verify(candidate, contents),
    );
}

test "an older image is refused even when correctly signed" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    try fixture.applyUpdate("version two", .{
        .major = 2,
        .minor = 0,
        .patch = 0,
        .security_generation = 1,
    });

    const older: Version = .{ .major = 1, .minor = 0, .patch = 0, .security_generation = 1 };
    const contents = "the previous image";
    const candidate = try fixture.image(contents, older);

    // Correctly signed by the release key, and still refused.
    try std.testing.expectError(
        error.RollbackRefused,
        fixture.updater.verify(candidate, contents),
    );
}

test "an image below the security floor is refused after the floor rises" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    // A release that fixes something raises the floor once it is confirmed.
    try fixture.applyUpdate("a security release", .{
        .major = 1,
        .minor = 1,
        .patch = 0,
        .security_generation = 5,
    });
    try std.testing.expectEqual(@as(u32, 5), fixture.updater.security_floor);

    // A later version at an older security generation reintroduces the fault.
    const contents = "a newer version without the fix";
    const candidate = try fixture.image(contents, .{
        .major = 1,
        .minor = 2,
        .patch = 0,
        .security_generation = 4,
    });
    try std.testing.expectError(
        error.RollbackRefused,
        fixture.updater.verify(candidate, contents),
    );
}

test "the security floor never falls" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    try fixture.applyUpdate("a security release", .{
        .major = 1,
        .minor = 1,
        .patch = 0,
        .security_generation = 5,
    });

    // A newer image at the same generation must not lower the floor.
    try fixture.applyUpdate("a later release", .{
        .major = 1,
        .minor = 2,
        .patch = 0,
        .security_generation = 5,
    });
    try std.testing.expectEqual(@as(u32, 5), fixture.updater.security_floor);
}

test "the floor rises only on a confirmed boot" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "a security release that does not start";
    const candidate = try fixture.image(contents, .{
        .major = 1,
        .minor = 1,
        .patch = 0,
        .security_generation = 9,
    });
    _ = try fixture.updater.stage(candidate, contents);
    try fixture.updater.finishStaging(candidate, contents);
    try fixture.updater.selectForNextBoot();

    // Raising the floor before the image is known to work would strand the
    // device below its own floor when the update fails.
    try std.testing.expectEqual(@as(u32, 1), fixture.updater.security_floor);

    for (0..max_boot_attempts) |_| try fixture.updater.reportBootFailure();
    try std.testing.expectEqual(@as(u32, 1), fixture.updater.security_floor);
}

test "at least one slot boots at every point of an update" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "the next image";
    const candidate = try fixture.image(contents, next_version);

    try std.testing.expect(fixture.updater.hasBootableSlot());
    _ = try fixture.updater.stage(candidate, contents);
    try std.testing.expect(fixture.updater.hasBootableSlot());
    try fixture.updater.finishStaging(candidate, contents);
    try std.testing.expect(fixture.updater.hasBootableSlot());
    try fixture.updater.selectForNextBoot();
    try std.testing.expect(fixture.updater.hasBootableSlot());
    try fixture.updater.confirmBoot();
    try std.testing.expect(fixture.updater.hasBootableSlot());
}

test "an update can be abandoned deliberately at any stage before commitment" {
    const stages = [_]enum { after_stage, after_finish, after_select }{
        .after_stage,
        .after_finish,
        .after_select,
    };

    for (stages) |stop_at| {
        var fixture: Fixture = undefined;
        try Fixture.init(&fixture);

        const contents = "the next image";
        const candidate = try fixture.image(contents, next_version);

        _ = try fixture.updater.stage(candidate, contents);
        if (stop_at != .after_stage) try fixture.updater.finishStaging(candidate, contents);
        if (stop_at == .after_select) try fixture.updater.selectForNextBoot();

        try fixture.updater.rollBack();

        try std.testing.expectEqual(Stage.rolled_back, fixture.updater.current_stage);
        try std.testing.expectEqual(Slot.primary, fixture.updater.active);
        try std.testing.expect(fixture.updater.hasBootableSlot());
    }
}

test "a committed update cannot be abandoned" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    try fixture.applyUpdate("the next image", next_version);
    // Returning to the previous image after commitment is a downgrade, and
    // goes through the ordinary anti-rollback path rather than this one.
    try std.testing.expectError(error.WrongStage, fixture.updater.rollBack());
}

test "the stages that change what boots are exactly the ones that should" {
    for (std.enums.values(Stage)) |current| {
        const changed = current == .pending_verification or current == .committed;
        try std.testing.expectEqual(changed, current.hasChangedBootSelection());
    }
}

test "an update cannot skip a stage" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    // Selecting before anything is staged.
    try std.testing.expectError(error.WrongStage, fixture.updater.selectForNextBoot());
    try std.testing.expectError(error.WrongStage, fixture.updater.confirmBoot());

    const contents = "the next image";
    const candidate = try fixture.image(contents, next_version);
    _ = try fixture.updater.stage(candidate, contents);

    // Selecting before the write finished.
    try std.testing.expectError(error.WrongStage, fixture.updater.selectForNextBoot());
    // Starting a second update while one is in progress.
    try std.testing.expectError(error.WrongStage, fixture.updater.stage(candidate, contents));
}

test "an oversized image is refused before it is written" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    var candidate = try fixture.image("the next image", next_version);
    candidate.size_bytes = max_image_bytes + 1;

    try std.testing.expectError(
        error.ImageTooLarge,
        fixture.updater.verify(candidate, "the next image"),
    );
}

test "successive updates alternate slots" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    try std.testing.expectEqual(Slot.primary, fixture.updater.active);

    try fixture.applyUpdate("second", .{ .major = 2, .minor = 0, .patch = 0, .security_generation = 1 });
    try std.testing.expectEqual(Slot.secondary, fixture.updater.active);

    try fixture.applyUpdate("third", .{ .major = 3, .minor = 0, .patch = 0, .security_generation = 1 });
    try std.testing.expectEqual(Slot.primary, fixture.updater.active);

    // The slot just replaced still holds a bootable image, so a failure of the
    // next update has somewhere to go.
    try std.testing.expect(fixture.updater.slotState(.secondary).bootable);
}

test "version ordering is total and consistent" {
    const base: Version = .{ .major = 1, .minor = 2, .patch = 3, .security_generation = 1 };
    const same: Version = .{ .major = 1, .minor = 2, .patch = 3, .security_generation = 9 };

    // The security generation is deliberately not part of the ordering: it
    // gates installation separately from which release is newer.
    try std.testing.expectEqual(std.math.Order.eq, base.order(same));
    try std.testing.expect((Version{
        .major = 1,
        .minor = 2,
        .patch = 4,
        .security_generation = 1,
    }).isNewerThan(base));
    try std.testing.expect(!base.isNewerThan(base));
}

test "an interrupted staging write leaves a recoverable device" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    const contents = "the next image";
    const candidate = try fixture.image(contents, next_version);
    _ = try fixture.updater.stage(candidate, contents);

    // The process stops here. On restart the staged slot is not bootable, the
    // active slot is, and a fresh update can begin after abandoning this one.
    try std.testing.expect(!fixture.updater.slotState(.secondary).bootable);
    try std.testing.expect(fixture.updater.slotState(.primary).bootable);

    try fixture.updater.rollBack();
    _ = try fixture.updater.stage(candidate, contents);
    try fixture.updater.finishStaging(candidate, contents);
    try fixture.updater.selectForNextBoot();
    try fixture.updater.confirmBoot();

    try std.testing.expectEqual(Slot.secondary, fixture.updater.active);
    _ = package_model;
    _ = identity;
}
