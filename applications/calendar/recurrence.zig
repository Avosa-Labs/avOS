//! Recurrence: expanding a repeating event into the concrete times it actually occupies, the way a
//! real calendar must, so a weekly stand-up is one rule that produces many occurrences rather than a
//! row copied by hand.
//!
//! A recurring event is not a list of events — it is a rule (a start, how often it repeats, and how
//! many times), and everything a calendar shows about it is derived from that rule: its free/busy,
//! its next occurrence, whether a given time is one of its instances. This module is that derivation,
//! kept pure and exact. From a start slot it steps by the rule's period — a day, a week, times the
//! interval — producing exactly `count` occurrences (or as many as fit the caller's buffer), never
//! one before the start, never a duplicate, never drifting off the period. Getting this wrong is how
//! calendars double-book or lose an instance; getting it right is one careful function with the
//! properties pinned by test. Civil-time correctness — that "every Monday at 09:00" stays 09:00
//! across a daylight-saving change — is layered on top of this slot arithmetic by the civil-time
//! model; the rule itself, expanded here, is exact.

const std = @import("std");

/// How often an event repeats. Extensible to monthly and yearly over a civil-time model; the two
/// fixed-period frequencies are exact over slots today.
pub const Frequency = enum { daily, weekly };

/// A recurrence rule: from a start, repeat every `interval` periods of `frequency`, for `count`
/// occurrences (including the first). An interval of zero is not a repetition and is rejected.
pub const Recurrence = struct {
    frequency: Frequency,
    interval: u32 = 1,
    count: u32,

    /// The number of slots between consecutive occurrences, given how many slots make a day. A day
    /// is `slots_per_day`; a week is seven of those; the interval multiplies it.
    pub fn period(rule: Recurrence, slots_per_day: u32) u32 {
        const base: u32 = switch (rule.frequency) {
            .daily => slots_per_day,
            .weekly => slots_per_day * 7,
        };
        return base * rule.interval;
    }

    /// Whether the rule is well-formed: it must repeat at least once, and by a real period.
    pub fn valid(rule: Recurrence) bool {
        return rule.count >= 1 and rule.interval >= 1;
    }
};

/// Expands a recurrence into the slots it occupies, starting at `start_slot`, writing occurrences in
/// time order into `out`. Returns the occurrences written: `count`, or as many as fit `out`,
/// whichever is fewer. An invalid rule produces nothing. The first occurrence is always the start.
pub fn occurrences(start_slot: u32, rule: Recurrence, slots_per_day: u32, out: []u32) []const u32 {
    if (!rule.valid() or slots_per_day == 0) return out[0..0];
    const step = rule.period(slots_per_day);
    var n: usize = 0;
    var slot = start_slot;
    while (n < rule.count and n < out.len) {
        out[n] = slot;
        n += 1;
        // Stop before overflowing the slot space rather than wrapping to an earlier time.
        const next = @addWithOverflow(slot, step);
        if (next[1] != 0) break;
        slot = next[0];
    }
    return out[0..n];
}

/// Whether a given slot is one of a recurrence's occurrences — the free/busy question for a repeating
/// event, answered without materialising every instance: a slot is an occurrence iff it is at or
/// after the start, lands exactly on the period, and falls within the count.
pub fn occupies(start_slot: u32, rule: Recurrence, slots_per_day: u32, slot: u32) bool {
    if (!rule.valid() or slots_per_day == 0 or slot < start_slot) return false;
    const step = rule.period(slots_per_day);
    const offset = slot - start_slot;
    if (offset % step != 0) return false;
    const index = offset / step;
    return index < rule.count;
}

// --- Tests ---

const testing = std.testing;

const day: u32 = 24; // slots per day in the current hourly model

test "a daily rule produces exactly count occurrences, one day apart" {
    var buf: [16]u32 = undefined;
    const got = occurrences(9, .{ .frequency = .daily, .count = 3 }, day, &buf);
    try testing.expectEqualSlices(u32, &.{ 9, 33, 57 }, got);
}

test "a weekly rule steps seven days, and an interval multiplies the period" {
    var buf: [16]u32 = undefined;
    const weekly = occurrences(9, .{ .frequency = .weekly, .count = 2 }, day, &buf);
    try testing.expectEqualSlices(u32, &.{ 9, 9 + 7 * day }, weekly);
    // Every other day.
    const biweekly = occurrences(0, .{ .frequency = .daily, .interval = 2, .count = 3 }, day, &buf);
    try testing.expectEqualSlices(u32, &.{ 0, 2 * day, 4 * day }, biweekly);
}

test "expansion never exceeds the caller's buffer" {
    var buf: [2]u32 = undefined;
    const got = occurrences(0, .{ .frequency = .daily, .count = 100 }, day, &buf);
    try testing.expectEqual(@as(usize, 2), got.len);
}

test "an invalid rule produces nothing" {
    var buf: [8]u32 = undefined;
    try testing.expectEqual(@as(usize, 0), occurrences(0, .{ .frequency = .daily, .count = 0 }, day, &buf).len);
    try testing.expectEqual(@as(usize, 0), occurrences(0, .{ .frequency = .daily, .interval = 0, .count = 3 }, day, &buf).len);
}

test "occupies agrees with the expansion, swept" {
    // The membership test must answer exactly what the expansion contains — no instance claimed that
    // was not produced, none produced that is not claimed.
    const rule = Recurrence{ .frequency = .daily, .interval = 3, .count = 5 };
    const start: u32 = 10;
    var buf: [8]u32 = undefined;
    const produced = occurrences(start, rule, day, &buf);
    var slot: u32 = 0;
    while (slot < start + 20 * day) : (slot += 1) {
        var in_expansion = false;
        for (produced) |o| {
            if (o == slot) in_expansion = true;
        }
        try testing.expectEqual(in_expansion, occupies(start, rule, day, slot));
    }
}

test "no occurrence ever falls before the start" {
    var buf: [32]u32 = undefined;
    const got = occurrences(100, .{ .frequency = .weekly, .interval = 1, .count = 20 }, day, &buf);
    for (got) |o| try testing.expect(o >= 100);
}
