//! Deciding when an automatic backup runs, so a person's data is protected on a
//! regular cadence without a backup ever interrupting them or spending their money.
//!
//! An automatic backup is only useful if it actually happens, and only acceptable if
//! it happens invisibly. Those two pull against each other, and the schedule is where
//! they are reconciled. A backup should run often enough that little is ever lost —
//! so once enough time has passed since the last one, it is due — but it must run
//! only when it costs the person nothing they would notice: while the device is
//! charging so it does not drain the battery, on an unmetered link so it does not
//! spend a data allowance, and while the device is idle so it does not compete with
//! what the person is doing. A backup that is due but whose conditions are not met
//! waits rather than forcing itself, because a backup that wakes a hot phone on
//! cellular mid-task teaches a person to turn backups off, which is the one outcome
//! that actually loses data.
//!
//! This module copies nothing. It decides whether an automatic backup should run now,
//! given how long since the last one and the current conditions, as a pure function.

const std = @import("std");

/// How long since the last successful backup makes another one due, in
/// milliseconds. A day: often enough that little is lost, rare enough to be cheap.
pub const backup_interval_ms: i64 = 24 * 60 * 60 * 1000;

/// The device conditions an automatic backup needs.
pub const Conditions = struct {
    /// Milliseconds since the last successful backup.
    since_last_ms: i64,
    /// Whether the device is charging.
    charging: bool,
    /// Whether the current link is unmetered.
    unmetered: bool,
    /// Whether the device is idle — the person is not actively using it.
    idle: bool,
};

/// Why an automatic backup did not run.
pub const Deferral = enum {
    /// Not enough time has passed since the last backup.
    not_due,
    /// The device is not charging.
    not_charging,
    /// The link is metered.
    metered,
    /// The person is using the device.
    device_busy,
};

/// The scheduling decision.
pub const Decision = union(enum) {
    run,
    defer_until: Deferral,

    pub fn runs(decision: Decision) bool {
        return decision == .run;
    }
};

/// Decides whether an automatic backup should run now.
///
/// The backup must first be due — enough time since the last one — because running
/// more often than the interval wastes work for little gain. Once due, every comfort
/// condition must hold: charging so the battery is not drained, unmetered so no data
/// allowance is spent, and idle so the person is not interrupted. A due backup whose
/// conditions are not all met waits for them rather than forcing itself, and the
/// specific unmet condition is named so a caller can retry when it changes.
pub fn shouldRun(conditions: Conditions) Decision {
    if (conditions.since_last_ms < backup_interval_ms) return .{ .defer_until = .not_due };
    if (!conditions.charging) return .{ .defer_until = .not_charging };
    if (!conditions.unmetered) return .{ .defer_until = .metered };
    if (!conditions.idle) return .{ .defer_until = .device_busy };
    return .run;
}

fn conds(since: i64, charging: bool, unmetered: bool, idle: bool) Conditions {
    return .{ .since_last_ms = since, .charging = charging, .unmetered = unmetered, .idle = idle };
}

const due = backup_interval_ms;

test "a due backup runs when every condition is met" {
    try std.testing.expect(shouldRun(conds(due, true, true, true)).runs());
}

test "a backup not yet due waits" {
    try std.testing.expectEqual(Decision{ .defer_until = .not_due }, shouldRun(conds(due - 1, true, true, true)));
}

test "the interval boundary is inclusive" {
    try std.testing.expect(shouldRun(conds(backup_interval_ms, true, true, true)).runs());
}

test "a due backup waits while not charging" {
    try std.testing.expectEqual(Decision{ .defer_until = .not_charging }, shouldRun(conds(due, false, true, true)));
}

test "a due backup waits on a metered link" {
    try std.testing.expectEqual(Decision{ .defer_until = .metered }, shouldRun(conds(due, true, false, true)));
}

test "a due backup waits while the person is using the device" {
    try std.testing.expectEqual(Decision{ .defer_until = .device_busy }, shouldRun(conds(due, true, true, false)));
}

test "a backup never runs unless due and every condition holds, swept" {
    // The invisible-backup property: a run implies due, charging, unmetered, and idle
    // all at once.
    for ([_]i64{ due - 1, due, due * 2 }) |since| {
        for ([_]bool{ false, true }) |charging| {
            for ([_]bool{ false, true }) |unmetered| {
                for ([_]bool{ false, true }) |idle| {
                    const decision = shouldRun(conds(since, charging, unmetered, idle));
                    if (decision.runs()) {
                        try std.testing.expect(since >= backup_interval_ms and charging and unmetered and idle);
                    }
                }
            }
        }
    }
}
