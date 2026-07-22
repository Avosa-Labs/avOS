//! What a device does when the boot chain does not complete.
//!
//! A device that cannot verify what comes next has three honest answers: run a
//! recovery image, go back to the slot that last worked, or stop. Booting the
//! unverified stage anyway is not among them, however inconvenient stopping is.
//!
//! The choice depends on where the failure happened. The earlier it is, the less
//! of the device can be trusted to run the recovery, so an early failure has
//! fewer options rather than more.

const std = @import("std");

/// Why the chain stopped.
pub const Failure = enum {
    /// A stage was not signed by the key its position accepts.
    signature_rejected,
    /// A stage was older than one the device has already booted.
    rollback_refused,
    /// A stage was reached out of order.
    out_of_order,
    /// The measurement log could not record what was about to run.
    unmeasurable,
};

/// The outcome.
pub const Outcome = enum {
    /// Boot a minimal image that can repair or reinstall.
    boot_recovery_image,
    /// Return to the previous system slot, which last booted successfully.
    previous_slot,
    /// Stop. Nothing trustworthy is available to run.
    halt,

    /// Whether this leaves the device usable by its owner.
    pub fn leavesDeviceUsable(outcome: Outcome) bool {
        return outcome != .halt;
    }
};

/// What the device knows about its alternatives when it has to choose.
pub const Available = struct {
    /// Whether the recovery image itself verified. A recovery image that did
    /// not verify is not a recovery path; it is another unverified stage.
    recovery_image_verified: bool,
    /// Whether a previous slot exists and last booted successfully.
    previous_slot_bootable: bool,
};

/// How far the chain got before it stopped.
///
/// Expressed as a depth rather than a stage name so this module does not depend
/// on the chain that calls it.
pub const Depth = enum {
    /// Failed at or before the stage that loads the recovery image. Nothing
    /// here is trusted to find one.
    before_recovery_is_loadable,
    /// Failed after enough of the device is running to load a recovery image.
    after_recovery_is_loadable,
};

/// Chooses what to do.
pub fn choose(failure: Failure, depth: Depth, available: Available) Outcome {
    return switch (failure) {
        // An unmeasurable or misordered boot means the chain itself is not
        // behaving. Nothing it could load would be trustworthy either.
        .out_of_order, .unmeasurable => .halt,

        // A refused downgrade means the installed image is too old. The
        // previous slot is older still and would be refused too, so it is not
        // an alternative even when it exists.
        .rollback_refused => if (depth == .after_recovery_is_loadable and
            available.recovery_image_verified)
            .boot_recovery_image
        else
            .halt,

        .signature_rejected => switch (depth) {
            .after_recovery_is_loadable => if (available.recovery_image_verified)
                .boot_recovery_image
            else if (available.previous_slot_bootable)
                .previous_slot
            else
                .halt,
            // Too early to load anything selectively; the slot that worked is
            // the only alternative to stopping.
            .before_recovery_is_loadable => if (available.previous_slot_bootable)
                .previous_slot
            else
                .halt,
        },
    };
}

/// What the owner is told.
///
/// A device that has stopped must say why in terms its owner can act on.
/// "Verification failed" is accurate and useless; the message has to name what
/// happened and what they can do.
pub fn explain(outcome: Outcome, failure: Failure) []const u8 {
    return switch (outcome) {
        .boot_recovery_image => switch (failure) {
            .rollback_refused => "the installed system is older than this device accepts; starting recovery to reinstall",
            else => "the installed system could not be verified; starting recovery to repair it",
        },
        .previous_slot => "the installed system could not be verified; starting the previous version instead",
        .halt => "the installed system could not be verified and no trusted alternative is available; this device needs servicing",
    };
}

const everything: Available = .{ .recovery_image_verified = true, .previous_slot_bootable = true };
const nothing: Available = .{ .recovery_image_verified = false, .previous_slot_bootable = false };

test "a late signature failure uses recovery when it is available" {
    try std.testing.expectEqual(
        Outcome.boot_recovery_image,
        choose(.signature_rejected, .after_recovery_is_loadable, everything),
    );
}

test "an early failure cannot reach recovery and falls back to the previous slot" {
    // Nothing this early is trusted to find a recovery image, so the offer of
    // one is deliberately ignored.
    try std.testing.expectEqual(
        Outcome.previous_slot,
        choose(.signature_rejected, .before_recovery_is_loadable, everything),
    );
}

test "with no alternative the device stops rather than booting something unverified" {
    const outcome = choose(.signature_rejected, .before_recovery_is_loadable, nothing);
    try std.testing.expectEqual(Outcome.halt, outcome);
    try std.testing.expect(!outcome.leavesDeviceUsable());
}

test "an unverified recovery image is not a recovery path" {
    try std.testing.expectEqual(
        Outcome.previous_slot,
        choose(.signature_rejected, .after_recovery_is_loadable, .{
            .recovery_image_verified = false,
            .previous_slot_bootable = true,
        }),
    );
    try std.testing.expectEqual(
        Outcome.halt,
        choose(.signature_rejected, .after_recovery_is_loadable, nothing),
    );
}

test "a refused downgrade never falls back to an older slot" {
    // The previous slot is older still, so it would be refused for the same
    // reason. Offering it would be a loop rather than a recovery.
    try std.testing.expectEqual(
        Outcome.halt,
        choose(.rollback_refused, .after_recovery_is_loadable, .{
            .recovery_image_verified = false,
            .previous_slot_bootable = true,
        }),
    );
    try std.testing.expectEqual(
        Outcome.boot_recovery_image,
        choose(.rollback_refused, .after_recovery_is_loadable, everything),
    );
}

test "a chain that is misbehaving stops regardless of what is available" {
    for ([_]Failure{ .out_of_order, .unmeasurable }) |failure| {
        for (std.enums.values(Depth)) |depth| {
            try std.testing.expectEqual(Outcome.halt, choose(failure, depth, everything));
        }
    }
}

test "every failure and every situation has a defined outcome" {
    for (std.enums.values(Failure)) |failure| {
        for (std.enums.values(Depth)) |depth| {
            for ([_]bool{ true, false }) |recovery_verified| {
                for ([_]bool{ true, false }) |slot_bootable| {
                    const outcome = choose(failure, depth, .{
                        .recovery_image_verified = recovery_verified,
                        .previous_slot_bootable = slot_bootable,
                    });
                    // Every outcome is explainable to the owner.
                    try std.testing.expect(explain(outcome, failure).len > 0);
                }
            }
        }
    }
}

test "no outcome runs the stage that failed to verify" {
    // The property the whole module exists to hold: whatever is chosen, it is
    // never the unverified stage.
    for (std.enums.values(Failure)) |failure| {
        for (std.enums.values(Depth)) |depth| {
            const outcome = choose(failure, depth, everything);
            try std.testing.expect(outcome == .boot_recovery_image or
                outcome == .previous_slot or
                outcome == .halt);
        }
    }
}

test "a halted device explains itself in terms its owner can act on" {
    const message = explain(.halt, .signature_rejected);
    try std.testing.expect(std.mem.indexOf(u8, message, "servicing") != null);

    // The downgrade case says something different, because the remedy differs.
    try std.testing.expect(!std.mem.eql(
        u8,
        explain(.boot_recovery_image, .rollback_refused),
        explain(.boot_recovery_image, .signature_rejected),
    ));
}
