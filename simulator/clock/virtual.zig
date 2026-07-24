//! Deciding how the simulator's virtual clock advances, so simulated time moves only forward and only
//! by explicit ticks, never from the wall clock — which is what makes a run reproducible.
//!
//! A deterministic simulation cannot read the wall clock. If it did, the same scenario run twice would
//! see different timestamps, timeouts would fire at different simulated moments, and a failure seen once
//! could not be reproduced — the opposite of what a simulator is for. So simulated time is a value the
//! scenario advances deliberately: it starts at a known point and moves forward only when the run ticks
//! it, by an explicit amount. Two rules keep it sound. Time never moves backward — an advance is by a
//! non-negative amount, so ordering is stable and a later event never carries an earlier timestamp. And
//! time comes only from ticks, never from the host clock, so a scenario replayed with the same ticks
//! observes the identical sequence of instants. A clock the run fully controls is the foundation every
//! other deterministic behaviour — scheduling, timeouts, fault timing — is built on.
//!
//! This module reads no clock. It decides the virtual time after an advance, from the current time and
//! the tick, as a pure function.

const std = @import("std");

/// The simulator's virtual time, in abstract ticks since the scenario's start.
pub const Instant = u64;

/// The starting instant of every scenario: a known, fixed origin.
pub const origin: Instant = 0;

/// The virtual time after advancing the current time by a number of ticks.
///
/// The advance is by a non-negative tick count and saturates rather than wrapping, so time only ever
/// moves forward and never rolls over into an earlier instant. The result depends solely on the
/// current time and the tick — never on any external clock — so the same sequence of advances always
/// produces the same instants.
pub fn advance(current: Instant, ticks: u64) Instant {
    return current +| ticks;
}

test "the clock starts at the fixed origin" {
    try std.testing.expectEqual(@as(Instant, 0), origin);
}

test "advancing moves time forward by the tick" {
    try std.testing.expectEqual(@as(Instant, 5), advance(origin, 5));
    try std.testing.expectEqual(@as(Instant, 12), advance(5, 7));
}

test "a zero tick leaves time unchanged" {
    try std.testing.expectEqual(@as(Instant, 9), advance(9, 0));
}

test "the clock saturates rather than wrapping backward" {
    try std.testing.expectEqual(std.math.maxInt(Instant), advance(std.math.maxInt(Instant), 3));
}

test "time never moves backward across a sequence of advances, swept" {
    // The monotonicity property: every advance yields an instant at least the current one.
    var current: Instant = origin;
    const ticks = [_]u64{ 3, 0, 100, 1, 0, 7 };
    for (ticks) |tick| {
        const next = advance(current, tick);
        try std.testing.expect(next >= current);
        current = next;
    }
}
