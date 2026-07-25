//! Boot integration: a failure partway through the chain drives recovery, and a
//! committed update that will not boot rolls back to the slot that did.
//!
//! The unit tests prove each piece in isolation; this proves they compose. A
//! chain that halts hands its failure to the recovery policy, which — bounded by
//! how many times recovery has already been tried — escalates from the recovery
//! image to the previous slot to a halt. Separately, the A/B slots and the
//! verified-boot check together give rollback something real to fall back to.

const std = @import("std");
const recovery = @import("../recovery/recovery.zig");
const slots = @import("../slots/slots.zig");
const verified = @import("../verified/verified.zig");
const measurements = @import("../measurements/measurements.zig");

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

fn key() !Ed25519.KeyPair {
    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(77);
    return Ed25519.KeyPair.generateDeterministic(seed);
}

fn sign(pair: Ed25519.KeyPair, contents: []const u8, version: u32) !verified.Image {
    const digest = measurements.digestOf(contents);
    const signature = try pair.sign(&digest, null);
    return .{ .contents = contents, .version = version, .signature = signature.toBytes() };
}

test "a signature failure after recovery-is-loadable escalates over repeated attempts" {
    // Attempt 0 boots the recovery image; if that keeps failing the ladder steps
    // to the previous slot and then halts, so a broken device does not loop.
    const available: recovery.Available = .{ .recovery_image_verified = true, .previous_slot_bootable = true };
    try testing.expectEqual(
        recovery.Outcome.boot_recovery_image,
        recovery.chooseBounded(.signature_rejected, .after_recovery_is_loadable, available, 0),
    );
    try testing.expectEqual(
        recovery.Outcome.previous_slot,
        recovery.chooseBounded(.signature_rejected, .after_recovery_is_loadable, available, 1),
    );
    try testing.expectEqual(
        recovery.Outcome.halt,
        recovery.chooseBounded(.signature_rejected, .after_recovery_is_loadable, available, recovery.max_attempts),
    );
}

test "a verified update commits, fails to boot, and rolls back to the good slot" {
    const pair = try key();

    // The device is running slot a at version 5, known good.
    var ab: slots.Slots = .init(.a, 5);

    // A version 6 image is staged into slot b and passes verified boot.
    const image = try sign(pair, "kernel v6", 6);
    _ = try verified.verify(image, .{ .key = pair.public_key.toBytes() }, ab.get(.b).version);
    ab.stage(6);
    try ab.markVerified();
    try ab.commit();
    try testing.expectEqual(slots.Slot.b, ab.nextBoot());

    // Slot b fails to boot; the device rolls back to slot a, still good.
    const fallback = try ab.rollback();
    try testing.expectEqual(slots.Slot.a, fallback);
    try testing.expectEqual(slots.Slot.a, ab.nextBoot());
}

test "an image too old to run is refused before recovery is even consulted" {
    const pair = try key();
    // The floor is 6; a version-4 image is a downgrade and refused by verify,
    // which is the failure recovery would then see as a rollback refusal.
    const downgrade = try sign(pair, "kernel v4", 4);
    try testing.expectError(error.RollbackRefused, verified.verify(downgrade, .{ .key = pair.public_key.toBytes() }, 6));
    try testing.expectEqual(
        recovery.Outcome.halt,
        recovery.chooseBounded(.rollback_refused, .before_recovery_is_loadable, .{ .recovery_image_verified = false, .previous_slot_bootable = false }, 0),
    );
}
