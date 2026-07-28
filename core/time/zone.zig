//! Time zones and daylight saving: turning a wall-clock time into an instant while honouring the rule
//! that a 09:00 meeting stays 09:00 when the clocks change — the correctness a calendar lives or dies on.
//!
//! A person schedules in local wall-clock time; the machine stores instants. The offset between them is
//! not constant — most zones spring forward and fall back — so converting the two directions must know
//! whether daylight saving is in effect at that moment. Get it wrong and a recurring meeting drifts by
//! an hour twice a year, or a reminder fires at the wrong time on transition day. This module carries a
//! zone's standard offset and its DST rule (expressed as the transition dates it recurs on, like "second
//! Sunday of March to first Sunday of November"), computes the offset in force at a given time, and
//! converts local↔instant accordingly. The load-bearing property, pinned by test: a recurring local time
//! held constant across a spring-forward boundary stays that local time — the instant absorbs the shift,
//! the wall clock does not move.

const std = @import("std");
const civil = @import("civil.zig");
const timestamp = @import("time.zig");

/// A daylight-saving rule expressed the way zones actually publish it: DST begins on the n-th given
/// weekday of one month and ends on the n-th given weekday of another, at a local transition hour, and
/// shifts the clock by `delta_seconds` while in effect.
pub const DstRule = struct {
    delta_seconds: i32 = 3600,
    start_month: u8,
    start_nth: u8,
    start_dow: u8,
    end_month: u8,
    end_nth: u8,
    end_dow: u8,
    transition_hour: u8 = 2,
};

/// A time zone: a standard offset from UTC in seconds (east positive), and an optional DST rule.
pub const TimeZone = struct {
    standard_offset_seconds: i32,
    dst: ?DstRule = null,

    /// An hour-granularity ordinal for comparing a moment within a year against the DST transitions.
    fn ordinal(date: civil.Date, hour: u8) i64 {
        return civil.toDays(date) * 24 + hour;
    }

    /// Whether daylight saving is in effect at a given local wall-clock time. Handles both hemispheres:
    /// a northern rule (start month before end month) is active between the transitions; a southern rule
    /// (start after end) is active outside them, wrapping the year.
    pub fn isDstActive(zone: TimeZone, local: civil.DateTime) bool {
        const rule = zone.dst orelse return false;
        const year = local.date.year;
        const start_day = civil.nthWeekdayOfMonth(year, rule.start_month, rule.start_nth, rule.start_dow);
        const end_day = civil.nthWeekdayOfMonth(year, rule.end_month, rule.end_nth, rule.end_dow);
        const start = ordinal(.{ .year = year, .month = rule.start_month, .day = start_day }, rule.transition_hour);
        const end = ordinal(.{ .year = year, .month = rule.end_month, .day = end_day }, rule.transition_hour);
        const now = ordinal(local.date, local.hour);
        if (rule.start_month < rule.end_month) return now >= start and now < end;
        return now >= start or now < end; // southern hemisphere wraps the new year
    }

    /// The total offset from UTC in force at a local wall-clock time: standard, plus the DST delta while
    /// daylight saving is active.
    pub fn offsetAt(zone: TimeZone, local: civil.DateTime) i32 {
        const delta: i32 = if (zone.isDstActive(local)) (if (zone.dst) |r| r.delta_seconds else 0) else 0;
        return zone.standard_offset_seconds + delta;
    }

    /// The UTC instant a local wall-clock date-time denotes, applying the offset in force at that local
    /// time.
    pub fn localToInstant(zone: TimeZone, local: civil.DateTime) timestamp.Timestamp {
        return timestamp.Timestamp.fromSeconds(local.toTimestamp().seconds() - zone.offsetAt(local));
    }

    /// The local wall-clock date-time a UTC instant falls on. The offset depends on the local time, so it
    /// is resolved by taking the standard offset first, deciding DST from that approximate local time,
    /// then applying the corrected offset — exact everywhere but the one ambiguous hour a fall-back
    /// repeats, which resolves to standard time.
    pub fn instantToLocal(zone: TimeZone, ts: timestamp.Timestamp) civil.DateTime {
        const approx = civil.DateTime.fromTimestamp(timestamp.Timestamp.fromSeconds(ts.seconds() + zone.standard_offset_seconds));
        const offset = zone.offsetAt(approx);
        return civil.DateTime.fromTimestamp(timestamp.Timestamp.fromSeconds(ts.seconds() + offset));
    }
};

/// The US eastern zone as a worked example: UTC−5 standard, +1h DST from the second Sunday of March to
/// the first Sunday of November — the reference the property test exercises.
pub const us_eastern = TimeZone{
    .standard_offset_seconds = -5 * 3600,
    .dst = .{
        .start_month = 3,
        .start_nth = 2,
        .start_dow = 0,
        .end_month = 11,
        .end_nth = 1,
        .end_dow = 0,
    },
};

// --- Tests ---

const testing = std.testing;

test "DST is off in winter and on in summer for the eastern zone" {
    try testing.expect(!us_eastern.isDstActive(.{ .date = .{ .year = 2026, .month = 1, .day = 15 }, .hour = 12 }));
    try testing.expect(us_eastern.isDstActive(.{ .date = .{ .year = 2026, .month = 7, .day = 15 }, .hour = 12 }));
    // Standard offset in winter, one hour more in summer.
    try testing.expectEqual(@as(i32, -5 * 3600), us_eastern.offsetAt(.{ .date = .{ .year = 2026, .month = 1, .day = 15 }, .hour = 12 }));
    try testing.expectEqual(@as(i32, -4 * 3600), us_eastern.offsetAt(.{ .date = .{ .year = 2026, .month = 7, .day = 15 }, .hour = 12 }));
}

test "a local time round-trips through its instant away from the transition" {
    const local = civil.DateTime{ .date = .{ .year = 2026, .month = 7, .day = 15 }, .hour = 9, .minute = 30 };
    const back = us_eastern.instantToLocal(us_eastern.localToInstant(local));
    try testing.expectEqual(local.date.day, back.date.day);
    try testing.expectEqual(local.hour, back.hour);
    try testing.expectEqual(local.minute, back.minute);
}

test "a recurring 09:00 stays 09:00 across the spring-forward boundary" {
    // A daily 09:00 local meeting the days around the 2026-03-08 spring-forward. Each occurrence must
    // read back as 09:00 local, and the instant must absorb the lost hour — not the wall clock.
    var day: u8 = 6;
    var prev_instant: ?i64 = null;
    var crossed_shorter_gap = false;
    while (day <= 10) : (day += 1) {
        const local = civil.DateTime{ .date = .{ .year = 2026, .month = 3, .day = day }, .hour = 9 };
        const instant = us_eastern.localToInstant(local);
        // It reads back as 09:00 local, whatever DST did.
        const back = us_eastern.instantToLocal(instant);
        try testing.expectEqual(@as(u8, 9), back.hour);
        try testing.expectEqual(day, back.date.day);
        // Consecutive 09:00s are a day apart, except across the spring-forward day, which is an hour
        // shorter in real time because the clocks jumped forward.
        if (prev_instant) |p| {
            const gap = instant.seconds() - p;
            if (gap == 86_400 - 3_600) crossed_shorter_gap = true else try testing.expectEqual(@as(i64, 86_400), gap);
        }
        prev_instant = instant.seconds();
    }
    try testing.expect(crossed_shorter_gap); // the boundary really was crossed
}
