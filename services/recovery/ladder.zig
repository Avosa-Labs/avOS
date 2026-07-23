//! Choosing the least drastic action that can recover a fault, so a device heals
//! itself by restarting a service before it ever reaches for a reboot or a wipe.
//!
//! When something goes wrong, there is always a heavy hammer that would fix it — a
//! reboot fixes most things, a factory reset fixes almost everything — and reaching
//! for the hammer first is how a recoverable glitch becomes lost work. Recovery is a
//! ladder climbed one rung at a time: restart the failing service, and only if that
//! does not hold restart the subsystem it belongs to, and only then reboot, and only
//! as a last resort enter recovery mode where the person's data is at stake. Each
//! rung is tried and given a chance to hold before the next is considered, because
//! the whole point is to spend the smallest disruption that works. The one thing the
//! ladder never does is skip straight to a destructive action on a fault a restart
//! would have cleared, and it never takes a data-destroying step without the escalation
//! having earned it.
//!
//! This module performs no recovery. It chooses the next action given the current
//! rung and whether the last action held, as a pure function so the escalation is
//! monotone and never jumps past a gentler step that has not been tried.

const std = @import("std");

/// A recovery action, ordered from least to most disruptive.
pub const Action = enum(u8) {
    /// Restart just the failing service. The gentlest step.
    restart_service = 0,
    /// Restart the whole subsystem the service belongs to.
    restart_subsystem = 1,
    /// Reboot the device.
    reboot = 2,
    /// Enter recovery mode, where the person's data may be at stake. The last
    /// resort, never reached without the milder steps having failed.
    enter_recovery = 3,

    fn rung(action: Action) u8 {
        return @intFromEnum(action);
    }

    /// Whether this action risks the person's data.
    pub fn isDestructive(action: Action) bool {
        return action == .enter_recovery;
    }
};

/// What the recovery service should do next.
pub const Step = union(enum) {
    /// Perform this recovery action.
    perform: Action,
    /// The fault is resolved; nothing further is needed.
    resolved,
    /// Every rung has been tried and the device remains faulted. Escalate to a
    /// person; the ladder has nothing gentler left.
    exhausted,

    pub fn acts(step: Step) bool {
        return step == .perform;
    }
};

/// The gentlest rung the ladder starts from.
pub const first_action: Action = .restart_service;

/// Chooses the next recovery step.
///
/// If the last action held — the fault cleared — recovery is resolved and stops. If
/// it did not hold, the ladder climbs to the next rung up from the one just tried,
/// so a failed service restart escalates to a subsystem restart, then a reboot, then
/// recovery mode. Past the last rung there is nothing gentler to try, so the ladder
/// reports exhaustion for a person rather than looping. The climb is strictly one
/// rung at a time, so a destructive step is never reached without every milder step
/// having been tried and failed.
pub fn next(last_attempt: Action, held: bool) Step {
    if (held) return .resolved;
    const next_rung = last_attempt.rung() + 1;
    if (next_rung > Action.enter_recovery.rung()) return .exhausted;
    return .{ .perform = @enumFromInt(next_rung) };
}

test "a service restart that holds resolves the fault" {
    try std.testing.expectEqual(Step.resolved, next(.restart_service, true));
}

test "a failed service restart escalates to a subsystem restart" {
    try std.testing.expectEqual(Step{ .perform = .restart_subsystem }, next(.restart_service, false));
}

test "the ladder climbs one rung at a time" {
    try std.testing.expectEqual(Step{ .perform = .restart_subsystem }, next(.restart_service, false));
    try std.testing.expectEqual(Step{ .perform = .reboot }, next(.restart_subsystem, false));
    try std.testing.expectEqual(Step{ .perform = .enter_recovery }, next(.reboot, false));
}

test "past the last rung the ladder is exhausted" {
    try std.testing.expectEqual(Step.exhausted, next(.enter_recovery, false));
}

test "any rung that holds resolves, without climbing further" {
    for ([_]Action{ .restart_service, .restart_subsystem, .reboot, .enter_recovery }) |action| {
        try std.testing.expectEqual(Step.resolved, next(action, true));
    }
}

test "the destructive step is only ever reached from the rung directly below it" {
    // enter_recovery is produced only by a failed reboot, never skipped to from a
    // gentler rung.
    try std.testing.expectEqual(Step{ .perform = .enter_recovery }, next(.reboot, false));
    // No gentler failure yields the destructive step.
    try std.testing.expect(next(.restart_service, false).perform != .enter_recovery);
    try std.testing.expect(next(.restart_subsystem, false).perform != .enter_recovery);
}

test "recovery never skips a rung, swept" {
    // The monotone-escalation property: a failed action always escalates by exactly
    // one rung, so no milder step is ever skipped.
    const rungs = [_]Action{ .restart_service, .restart_subsystem, .reboot };
    for (rungs) |action| {
        switch (next(action, false)) {
            .perform => |chosen| try std.testing.expectEqual(action.rung() + 1, chosen.rung()),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "no destructive action is taken on a fault a gentler step cleared, swept" {
    // Whenever a rung holds, recovery resolves and never performs the destructive
    // step.
    for ([_]Action{ .restart_service, .restart_subsystem, .reboot }) |action| {
        const step = next(action, true);
        try std.testing.expect(!step.acts());
    }
}
