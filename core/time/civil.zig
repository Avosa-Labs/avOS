//! Civil time: the Gregorian calendar arithmetic a real calendar rests on — turning a wall-clock
//! date-and-time into an instant and back, exactly, so scheduling is correct rather than approximate.
//!
//! A monotonic instant is what the machine keeps; a person keeps a date and a time of day. Bridging
//! them correctly is the load-bearing arithmetic under every calendar: which year is a leap year, how
//! many days a month has, how many days lie between two dates, what date a given instant falls on.
//! Getting it a day wrong once is how a reminder fires on the wrong day. This module is that bridge,
//! pure and exact, using the standard proleptic-Gregorian day-count algorithm so a date round-trips to
//! a day number and back over any span, across century and leap boundaries alike. Time zones and
//! daylight saving — the rule that keeps a 09:00 meeting at 09:00 when the clocks change — layer on top
//! of this UTC civil arithmetic; the arithmetic itself is offset-free and unconditionally correct.

const std = @import("std");
const timestamp = @import("time.zig");

const seconds_per_day: i64 = 86_400;

/// A proleptic-Gregorian calendar date. Month is 1–12, day is 1–31; the year may be negative for
/// dates before year 1.
pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,
};

/// Whether a year is a leap year in the proleptic Gregorian calendar: divisible by 4, except
/// centuries, except those divisible by 400.
pub fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

/// The number of days in a month of a given year (accounting for February in a leap year).
pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// The day number of a date relative to 1970-01-01 (day 0), by the standard days-from-civil algorithm
/// (Howard Hinnant's), exact for any date. Negative for dates before the epoch.
pub fn toDays(date: Date) i64 {
    const y: i64 = if (date.month <= 2) @as(i64, date.year) - 1 else date.year;
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const m: i64 = date.month;
    const d: i64 = date.day;
    const doy: i64 = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// The date a day number (days since 1970-01-01) falls on — the inverse of `toDays`.
pub fn fromDays(days: i64) Date {
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp: i64 = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// The day of the week for a date: 0 = Sunday through 6 = Saturday. 1970-01-01 was a Thursday.
pub fn weekday(date: Date) u8 {
    const dow = @mod(toDays(date) + 4, 7); // epoch Thursday = 4
    return @intCast(if (dow < 0) dow + 7 else dow);
}

/// The day-of-month of the n-th given weekday in a month (n starting at 1), e.g. the 2nd Sunday of
/// March. If the month has fewer than n such weekdays, returns 0.
pub fn nthWeekdayOfMonth(year: i32, month: u8, n: u8, target_dow: u8) u8 {
    var count: u8 = 0;
    var day: u8 = 1;
    while (day <= daysInMonth(year, month)) : (day += 1) {
        if (weekday(.{ .year = year, .month = month, .day = day }) == target_dow) {
            count += 1;
            if (count == n) return day;
        }
    }
    return 0;
}

/// A civil date and time of day, interpreted in UTC by this module; a time zone applies its offset
/// on top.
pub const DateTime = struct {
    date: Date,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,

    /// The UTC instant this civil date-time denotes.
    pub fn toTimestamp(dt: DateTime) timestamp.Timestamp {
        const day_seconds: i64 = @as(i64, dt.hour) * 3600 + @as(i64, dt.minute) * 60 + dt.second;
        return timestamp.Timestamp.fromSeconds(toDays(dt.date) * seconds_per_day + day_seconds);
    }

    /// The civil date-time a UTC instant falls on.
    pub fn fromTimestamp(ts: timestamp.Timestamp) DateTime {
        const total = ts.seconds();
        const day = @divFloor(total, seconds_per_day);
        const rem = total - day * seconds_per_day; // [0, 86399]
        return .{
            .date = fromDays(day),
            .hour = @intCast(@divFloor(rem, 3600)),
            .minute = @intCast(@divFloor(@mod(rem, 3600), 60)),
            .second = @intCast(@mod(rem, 60)),
        };
    }
};

// --- Tests ---

const testing = std.testing;

test "the leap-year rule holds at the century and 400-year boundaries" {
    try testing.expect(isLeapYear(2000)); // divisible by 400
    try testing.expect(!isLeapYear(1900)); // century, not by 400
    try testing.expect(isLeapYear(2024));
    try testing.expect(!isLeapYear(2023));
    try testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try testing.expectEqual(@as(u8, 28), daysInMonth(2023, 2));
}

test "known dates map to known day numbers" {
    try testing.expectEqual(@as(i64, 0), toDays(.{ .year = 1970, .month = 1, .day = 1 }));
    try testing.expectEqual(@as(i64, -1), toDays(.{ .year = 1969, .month = 12, .day = 31 }));
    // 2000-03-01 is 11017 days after the epoch.
    try testing.expectEqual(@as(i64, 11017), toDays(.{ .year = 2000, .month = 3, .day = 1 }));
}

test "date round-trips through its day number across leap and century boundaries" {
    var day: i64 = -420_000;
    while (day <= 420_000) : (day += 97) { // ~2300 years, stepped to stay quick
        const date = fromDays(day);
        try testing.expectEqual(day, toDays(date));
        try testing.expect(date.month >= 1 and date.month <= 12);
        try testing.expect(date.day >= 1 and date.day <= daysInMonth(date.year, date.month));
    }
}

test "a civil date-time round-trips through its UTC instant" {
    const dt = DateTime{ .date = .{ .year = 2026, .month = 3, .day = 8 }, .hour = 9, .minute = 30, .second = 15 };
    const back = DateTime.fromTimestamp(dt.toTimestamp());
    try testing.expectEqual(dt.date.year, back.date.year);
    try testing.expectEqual(dt.date.month, back.date.month);
    try testing.expectEqual(dt.date.day, back.date.day);
    try testing.expectEqual(dt.hour, back.hour);
    try testing.expectEqual(dt.minute, back.minute);
    try testing.expectEqual(dt.second, back.second);
}

test "midnight epoch is instant zero" {
    const midnight = DateTime{ .date = .{ .year = 1970, .month = 1, .day = 1 } };
    try testing.expectEqual(@as(i64, 0), midnight.toTimestamp().seconds());
}

test "weekday and nth-weekday land on known dates" {
    try testing.expectEqual(@as(u8, 4), weekday(.{ .year = 1970, .month = 1, .day = 1 })); // Thursday
    try testing.expectEqual(@as(u8, 0), weekday(.{ .year = 2026, .month = 3, .day = 8 })); // Sunday
    // The 2nd Sunday of March 2026 is the 8th — the US spring-forward date.
    try testing.expectEqual(@as(u8, 8), nthWeekdayOfMonth(2026, 3, 2, 0));
    // The 1st Sunday of November 2026 is the 1st — the US fall-back date.
    try testing.expectEqual(@as(u8, 1), nthWeekdayOfMonth(2026, 11, 1, 0));
}
