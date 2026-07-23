//! Deciding whether a new task may be admitted for a requester, so one principal
//! cannot fill the machine with work and starve every other.
//!
//! Tasks are the unit of work the system runs, and running one costs bounded
//! resources — a slot in the scheduler, some memory, some time. If any principal
//! could submit unlimited tasks, one runaway agent would fill every slot and the
//! device would stop serving everyone else, a denial of service the device did to
//! itself. So task submission is admitted against the requester's own budget: each
//! principal may hold only so many tasks in flight at once and spend only so much of
//! a resource allowance across them, and a submission that would breach either is
//! refused at the door rather than queued to fail deep inside. The budget is
//! per-principal, so a busy principal slows only itself; the rest of the machine
//! keeps serving. Admission is the cheap check that keeps a shared machine fair
//! without the scheduler having to arbitrate a flood after the fact.
//!
//! This module runs no task. It decides whether a submission fits the requester's
//! in-flight and resource budgets, as a pure function over the current usage and the
//! request.

const std = @import("std");

/// A principal's current task usage against its budget.
pub const Usage = struct {
    /// Tasks currently in flight for this principal.
    in_flight: u32,
    /// The most tasks this principal may have in flight at once.
    max_in_flight: u32,
    /// Resource units currently committed across this principal's tasks.
    committed_units: u64,
    /// The most resource units this principal may commit at once.
    unit_budget: u64,
};

/// A task submission.
pub const Request = struct {
    /// The resource units this task would commit.
    units: u64,
};

/// Why a submission was refused.
pub const Refusal = enum {
    /// The principal already holds its maximum tasks in flight.
    too_many_in_flight,
    /// The task's units would push the principal over its resource budget.
    over_budget,
};

/// The admission decision.
pub const Decision = union(enum) {
    admit,
    refuse: Refusal,

    pub fn admitted(decision: Decision) bool {
        return decision == .admit;
    }
};

/// Decides whether a task submission is admitted for a principal.
///
/// The in-flight count must be below the principal's limit, and the task's units must
/// fit within the remaining budget. Either check failing refuses the submission at
/// the door, so a principal that has reached its limit slows only itself. The unit
/// check is computed in wide arithmetic so a large request cannot wrap the committed
/// total into a small in-budget number.
pub fn decide(usage: Usage, request: Request) Decision {
    if (usage.in_flight >= usage.max_in_flight) return .{ .refuse = .too_many_in_flight };
    const after = @as(u128, usage.committed_units) + request.units;
    if (after > usage.unit_budget) return .{ .refuse = .over_budget };
    return .admit;
}

fn usageOf(in_flight: u32, max_in_flight: u32, committed: u64, budget: u64) Usage {
    return .{
        .in_flight = in_flight,
        .max_in_flight = max_in_flight,
        .committed_units = committed,
        .unit_budget = budget,
    };
}

test "a submission within both budgets is admitted" {
    const usage = usageOf(2, 8, 100, 1000);
    try std.testing.expect(decide(usage, .{ .units = 100 }).admitted());
}

test "a principal at its in-flight limit is refused" {
    const usage = usageOf(8, 8, 100, 1000);
    try std.testing.expectEqual(Decision{ .refuse = .too_many_in_flight }, decide(usage, .{ .units = 1 }));
}

test "a task that would exceed the unit budget is refused" {
    const usage = usageOf(2, 8, 900, 1000);
    try std.testing.expectEqual(Decision{ .refuse = .over_budget }, decide(usage, .{ .units = 200 }));
}

test "the unit budget boundary is inclusive" {
    const usage = usageOf(2, 8, 900, 1000);
    try std.testing.expect(decide(usage, .{ .units = 100 }).admitted());
    try std.testing.expectEqual(Decision{ .refuse = .over_budget }, decide(usage, .{ .units = 101 }));
}

test "the in-flight limit is checked before the budget" {
    // At the in-flight limit and over budget, the in-flight refusal is reported.
    const usage = usageOf(8, 8, 900, 1000);
    try std.testing.expectEqual(Decision{ .refuse = .too_many_in_flight }, decide(usage, .{ .units = 500 }));
}

test "a huge unit request cannot wrap the committed total into budget" {
    const usage = usageOf(1, 8, std.math.maxInt(u64) - 10, std.math.maxInt(u64));
    try std.testing.expectEqual(Decision{ .refuse = .over_budget }, decide(usage, .{ .units = 100 }));
}

test "no admission ever exceeds either budget, swept" {
    // The fairness property: an admitted task leaves the principal within both its
    // in-flight limit and its unit budget.
    const usage = usageOf(3, 8, 500, 1000);
    var units: u64 = 0;
    while (units <= 800) : (units += 100) {
        if (decide(usage, .{ .units = units }).admitted()) {
            try std.testing.expect(usage.in_flight < usage.max_in_flight);
            try std.testing.expect(usage.committed_units + units <= usage.unit_budget);
        }
    }
}
