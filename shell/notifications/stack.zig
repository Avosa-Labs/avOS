//! Ordering the notification stack and deciding when to collapse it, so the most important,
//! most recent notification is on top and a flood becomes a summary rather than a wall.
//!
//! The notification stack is a queue for a person's attention, and how it is ordered decides
//! whether it serves them. Two things order it. Priority comes first: a time-sensitive alert
//! sits above an ordinary update whatever their arrival times, because a person scanning the
//! stack should meet what matters most at the top. Within the same priority, the most recent
//! is higher, because newer is what a person is most likely acting on. And when many
//! notifications arrive from one source, showing them all is a wall that buries everything
//! else, so past a threshold they collapse into a single group the person can expand — the
//! difference between "you have forty-one messages" as one line and forty-one lines burying
//! the rest of the stack. Ordering by priority then recency, and collapsing a flood, is what
//! keeps the stack a useful triage rather than a source of dread.
//!
//! This module draws no banners. It orders two notifications and decides when a group
//! collapses, as pure functions.

const std = @import("std");

/// A notification's priority, ordered so a comparison decides precedence.
pub const Priority = enum(u8) {
    passive = 0,
    standard = 1,
    time_sensitive = 2,
    critical = 3,

    fn rank(priority: Priority) u8 {
        return @intFromEnum(priority);
    }
};

/// A notification as it sits in the stack.
pub const Notification = struct {
    priority: Priority,
    /// Arrival time in milliseconds since the epoch. Higher is more recent.
    arrived_ms: i64,
};

/// Whether notification `a` sorts above `b` in the stack.
///
/// Higher priority sorts above lower, whatever the times, so what matters most is on top.
/// Among equal priority, the more recent sorts above, because newer is what a person is most
/// likely acting on. The order is total and deterministic.
pub fn sortsAbove(a: Notification, b: Notification) bool {
    if (a.priority.rank() != b.priority.rank()) return a.priority.rank() > b.priority.rank();
    return a.arrived_ms > b.arrived_ms;
}

/// The number of notifications from one source at which the stack collapses them into a
/// single group. Below this they show individually.
pub const collapse_threshold: u32 = 3;

/// Whether a group of `count` notifications from one source should collapse into a summary.
pub fn shouldCollapse(count: u32) bool {
    return count >= collapse_threshold;
}

fn note(priority: Priority, arrived: i64) Notification {
    return .{ .priority = priority, .arrived_ms = arrived };
}

test "higher priority sorts above lower whatever the time" {
    // An old critical alert still sorts above a new passive one.
    try std.testing.expect(sortsAbove(note(.critical, 100), note(.passive, 1000)));
    try std.testing.expect(!sortsAbove(note(.passive, 1000), note(.critical, 100)));
}

test "among equal priority the more recent sorts above" {
    try std.testing.expect(sortsAbove(note(.standard, 200), note(.standard, 100)));
    try std.testing.expect(!sortsAbove(note(.standard, 100), note(.standard, 200)));
}

test "a small group does not collapse" {
    try std.testing.expect(!shouldCollapse(1));
    try std.testing.expect(!shouldCollapse(collapse_threshold - 1));
}

test "a flood collapses into a group" {
    try std.testing.expect(shouldCollapse(collapse_threshold));
    try std.testing.expect(shouldCollapse(41));
}

test "the ordering is a strict total order, swept" {
    // Antisymmetry: for two distinct notifications, exactly one sorts above the other; and no
    // notification sorts above itself.
    const notes = [_]Notification{
        note(.critical, 100), note(.standard, 200), note(.standard, 100), note(.passive, 300),
    };
    for (notes) |a| {
        try std.testing.expect(!sortsAbove(a, a)); // irreflexive
        for (notes) |b| {
            if (a.priority.rank() != b.priority.rank() or a.arrived_ms != b.arrived_ms) {
                // distinct: exactly one direction holds
                try std.testing.expect(sortsAbove(a, b) != sortsAbove(b, a));
            }
        }
    }
}

test "priority always dominates recency, swept" {
    // The what-matters-on-top property: a higher-priority notification always sorts above a
    // lower-priority one, however old.
    const priorities = [_]Priority{ .passive, .standard, .time_sensitive, .critical };
    for (priorities) |hi| {
        for (priorities) |lo| {
            if (hi.rank() > lo.rank()) {
                try std.testing.expect(sortsAbove(note(hi, 0), note(lo, 1_000_000)));
            }
        }
    }
}
