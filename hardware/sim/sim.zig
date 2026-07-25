//! SIM and eSIM presence and lock state.
//!
//! A subscriber identity is a small state machine with a sharp edge: a locked
//! SIM gives a few PIN attempts before it blocks, then a few PUK attempts to
//! unblock before it is permanently dead. Getting the counters wrong either locks
//! a user out of a working SIM or lets an attacker keep guessing, so the counting
//! is the whole point and is done here rather than trusted to a caller.
//!
//! It drives no silicon. A board reports whether a SIM is present and relays
//! verify results; this is the lock policy every board shares.

const std = @import("std");

/// The default attempt budgets, matching the common carrier values.
pub const default_pin_attempts: u8 = 3;
pub const default_puk_attempts: u8 = 10;

pub const Presence = enum { absent, present };

pub const Lock = enum {
    /// No PIN required, or already unlocked this session.
    unlocked,
    /// A PIN is required to use the subscriber identity.
    pin_required,
    /// PIN attempts exhausted; only the PUK can recover it.
    puk_required,
    /// PUK attempts exhausted. The identity is permanently unusable.
    dead,
};

pub const Error = error{
    /// No SIM is present to act on.
    Absent,
    /// The code did not match; an attempt was spent.
    WrongCode,
    /// The identity is in a state this action does not apply to.
    NotApplicable,
    /// The identity is permanently blocked.
    Dead,
};

/// One subscriber identity — a physical SIM or an eSIM profile.
pub const Subscriber = struct {
    presence: Presence = .present,
    lock: Lock = .pin_required,
    pin_remaining: u8 = default_pin_attempts,
    puk_remaining: u8 = default_puk_attempts,

    /// Attempts to unlock with a PIN. A correct PIN unlocks and resets the PIN
    /// budget; a wrong one spends an attempt and, when the budget is gone, moves
    /// to requiring the PUK.
    pub fn enterPin(subscriber: *Subscriber, matches: bool) Error!void {
        if (subscriber.presence == .absent) return error.Absent;
        if (subscriber.lock != .pin_required) return error.NotApplicable;

        if (matches) {
            subscriber.lock = .unlocked;
            subscriber.pin_remaining = default_pin_attempts;
            return;
        }
        subscriber.pin_remaining -= 1;
        if (subscriber.pin_remaining == 0) subscriber.lock = .puk_required;
        return error.WrongCode;
    }

    /// Attempts to unblock with a PUK. A correct PUK returns to PIN-required with
    /// a fresh PIN budget; a wrong one spends a PUK attempt and, when the PUK
    /// budget is gone, kills the identity permanently.
    pub fn enterPuk(subscriber: *Subscriber, matches: bool) Error!void {
        if (subscriber.presence == .absent) return error.Absent;
        if (subscriber.lock == .dead) return error.Dead;
        if (subscriber.lock != .puk_required) return error.NotApplicable;

        if (matches) {
            subscriber.lock = .pin_required;
            subscriber.pin_remaining = default_pin_attempts;
            return;
        }
        subscriber.puk_remaining -= 1;
        if (subscriber.puk_remaining == 0) subscriber.lock = .dead;
        return error.WrongCode;
    }

    /// Whether the identity can be used to attach to a network right now.
    pub fn isUsable(subscriber: Subscriber) bool {
        return subscriber.presence == .present and subscriber.lock == .unlocked;
    }
};

const testing = std.testing;

test "a correct pin unlocks and resets the attempt budget" {
    var sim: Subscriber = .{};
    try testing.expectError(error.WrongCode, sim.enterPin(false));
    try testing.expectEqual(@as(u8, 2), sim.pin_remaining);
    try sim.enterPin(true);
    try testing.expect(sim.isUsable());
    try testing.expectEqual(@as(u8, default_pin_attempts), sim.pin_remaining);
}

test "exhausting the pin moves to puk, and exhausting the puk kills the sim" {
    var sim: Subscriber = .{};
    for (0..default_pin_attempts) |_| try testing.expectError(error.WrongCode, sim.enterPin(false));
    try testing.expectEqual(Lock.puk_required, sim.lock);
    // A PIN no longer applies once the PUK is required.
    try testing.expectError(error.NotApplicable, sim.enterPin(true));

    for (0..default_puk_attempts) |_| try testing.expectError(error.WrongCode, sim.enterPuk(false));
    try testing.expectEqual(Lock.dead, sim.lock);
    try testing.expectError(error.Dead, sim.enterPuk(true));
}

test "a correct puk restores pin entry with a fresh budget" {
    var sim: Subscriber = .{};
    for (0..default_pin_attempts) |_| _ = sim.enterPin(false) catch {};
    try sim.enterPuk(true);
    try testing.expectEqual(Lock.pin_required, sim.lock);
    try testing.expectEqual(@as(u8, default_pin_attempts), sim.pin_remaining);
}

test "an absent sim can do nothing" {
    var sim: Subscriber = .{ .presence = .absent };
    try testing.expectError(error.Absent, sim.enterPin(true));
    try testing.expect(!sim.isUsable());
}
