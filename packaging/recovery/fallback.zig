//! Deciding which system slot a device boots after an update, so a build that fails to come up cleanly
//! falls back to the last one that did rather than leaving the device unbootable.
//!
//! A device keeps two system slots: the one it is running and the one an update is written into. The
//! danger of any update is the build that installs fine but does not boot — a device that applied an
//! update and then bricked is the worst outcome an update path can produce. So which slot the device
//! boots is a decision, not a default. A freshly updated slot boots on trial: it must confirm a
//! successful, healthy boot within a bounded number of attempts. If it confirms, it becomes the slot
//! the device commits to. If it exhausts its attempts without confirming, the device falls back to the
//! previous slot — known-good, because the device was running it before the update — so the worst an
//! update can do is send the device back to where it already was. A device is never left with only an
//! unconfirmed slot to boot. Trial-boot with fallback to the last known-good slot is what makes an
//! update safe to apply: failure is recoverable, not terminal.
//!
//! This module boots nothing. It decides which slot a device boots given the new slot's trial state, as
//! a pure function.

const std = @import("std");

/// The two system slots.
pub const Slot = enum { current, updated };

/// The trial state of a freshly updated slot.
pub const Trial = struct {
    /// Whether the updated slot has confirmed a successful, healthy boot.
    confirmed: bool,
    /// How many boot attempts the updated slot has consumed.
    attempts_used: u8,
    /// The maximum trial attempts allowed before falling back.
    attempts_allowed: u8,
};

/// Decides which slot the device boots.
///
/// If the updated slot has confirmed a healthy boot, the device boots it — the update is committed. If
/// it has not confirmed and still has trial attempts left, the device boots it again to keep trying. If
/// it has exhausted its attempts without confirming, the device falls back to the current slot, which is
/// known-good. A device therefore never ends up committed to a slot that never proved it can boot.
pub fn bootSlot(trial: Trial) Slot {
    if (trial.confirmed) return .updated;
    if (trial.attempts_used < trial.attempts_allowed) return .updated; // Keep trying within budget.
    return .current; // Exhausted trials — fall back to known-good.
}

fn makeTrial(confirmed: bool, used: u8, allowed: u8) Trial {
    return .{ .confirmed = confirmed, .attempts_used = used, .attempts_allowed = allowed };
}

test "a confirmed updated slot is booted" {
    try std.testing.expectEqual(Slot.updated, bootSlot(makeTrial(true, 3, 3)));
}

test "an unconfirmed slot with attempts left keeps trying" {
    try std.testing.expectEqual(Slot.updated, bootSlot(makeTrial(false, 1, 3)));
}

test "an unconfirmed slot out of attempts falls back to current" {
    try std.testing.expectEqual(Slot.current, bootSlot(makeTrial(false, 3, 3)));
}

test "the device never commits to an unconfirmed, exhausted slot, swept" {
    // The recoverability property: booting the updated slot means it is either confirmed or still
    // within its trial budget — never exhausted-and-unconfirmed.
    for ([_]bool{ false, true }) |confirmed| {
        var used: u8 = 0;
        while (used <= 5) : (used += 1) {
            const trial = makeTrial(confirmed, used, 3);
            if (bootSlot(trial) == .updated) {
                try std.testing.expect(confirmed or used < 3);
            }
        }
    }
}
