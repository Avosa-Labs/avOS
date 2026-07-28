//! A real calendar event: a local start time, a duration, and an optional repeat rule, resolved into
//! the actual instants it occupies — recurrence and daylight saving handled together, correctly.
//!
//! This is where the calendar's pieces meet the way a person means them: an event is scheduled at a
//! wall-clock time in a zone ("09:00 every weekday"), and what the machine needs is the set of instants
//! that denotes. The subtlety the two-part answer must get right is that recurrence steps over civil
//! dates — the next occurrence is the same local time one day or one week on — and each occurrence's
//! instant is then computed through the zone, so a repeating 09:00 stays 09:00 even across a daylight-
//! saving change, its instant absorbing the shift. Doing recurrence in instant-space instead would
//! drift the meeting by an hour twice a year; doing it in civil-date-space, as here, keeps it fixed to
//! the wall clock. An occurrence occupies the half-open span from its start to its start plus duration.

const std = @import("std");
// The platform slice (civil dates, zones, instants) reached through the frame — an app file may not
// import the core plane directly, so the framework re-exports what the schedule needs.
const core = @import("../framework/agent_app.zig").platform;
const recurrence = @import("recurrence.zig");

const civil = core.civil;
const zone = core.zone;

pub const Recurrence = recurrence.Recurrence;
pub const Frequency = recurrence.Frequency;

/// A scheduled event: its local start, the zone that start is expressed in, how long it lasts, and an
/// optional recurrence rule. Without a rule it happens once.
pub const Event = struct {
    start: civil.DateTime,
    zone: zone.TimeZone,
    duration_seconds: i64,
    repeat: ?Recurrence = null,

    /// The local start date-time of the i-th occurrence (0-based), stepping over civil dates so the
    /// wall-clock time is held fixed. For a non-recurring event only occurrence 0 exists.
    fn occurrenceStartLocal(event: Event, index: usize) civil.DateTime {
        const rule = event.repeat orelse return event.start;
        const days_per_step: i64 = switch (rule.frequency) {
            .daily => 1,
            .weekly => 7,
        };
        const days = @as(i64, @intCast(index)) * days_per_step * @as(i64, rule.interval);
        var local = event.start;
        local.date = civil.fromDays(civil.toDays(event.start.date) + days);
        return local; // same hour/minute/second — the wall-clock time is preserved across the step
    }

    /// How many occurrences the event has: its recurrence count, or one if it does not repeat.
    pub fn count(event: Event) usize {
        if (event.repeat) |rule| {
            return if (rule.valid()) rule.count else 0;
        }
        return 1;
    }

    /// The UTC instant the i-th occurrence starts at, resolved through the zone so daylight saving is
    /// applied per occurrence. Null if the index is past the event's occurrences.
    pub fn occurrenceStart(event: Event, index: usize) ?core.time.Timestamp {
        if (index >= event.count()) return null;
        return event.zone.localToInstant(event.occurrenceStartLocal(index));
    }

    /// Whether the event is occupying an instant — true when the instant falls within any occurrence's
    /// half-open [start, start+duration) span.
    pub fn occupies(event: Event, at: core.time.Timestamp) bool {
        var i: usize = 0;
        const n = event.count();
        while (i < n) : (i += 1) {
            const start = event.occurrenceStart(i) orelse return false;
            const s = start.seconds();
            if (at.seconds() >= s and at.seconds() < s + event.duration_seconds) return true;
        }
        return false;
    }
};

// --- Tests ---

const testing = std.testing;

fn eastern9am(year: i32, month: u8, day: u8) Event {
    return .{
        .start = .{ .date = .{ .year = year, .month = month, .day = day }, .hour = 9 },
        .zone = zone.us_eastern,
        .duration_seconds = 3600,
    };
}

test "a one-off event has a single occurrence occupying its hour" {
    const e = eastern9am(2026, 7, 15);
    try testing.expectEqual(@as(usize, 1), e.count());
    const start = e.occurrenceStart(0).?;
    try testing.expect(e.occupies(start));
    try testing.expect(e.occupies(core.time.Timestamp.fromSeconds(start.seconds() + 1800))); // mid-event
    try testing.expect(!e.occupies(core.time.Timestamp.fromSeconds(start.seconds() + 3600))); // exactly the end is outside
    try testing.expect(e.occurrenceStart(1) == null);
}

test "a daily 09:00 keeps its wall-clock time across the spring-forward day" {
    var e = eastern9am(2026, 3, 6);
    e.repeat = .{ .frequency = .daily, .count = 5 }; // Mar 6..10, crossing the Mar 8 spring-forward
    var i: usize = 0;
    var prev: ?i64 = null;
    var saw_short_gap = false;
    while (i < e.count()) : (i += 1) {
        const start = e.occurrenceStart(i).?;
        // Read back as local: every occurrence is 09:00 local.
        const local = zone.us_eastern.instantToLocal(start);
        try testing.expectEqual(@as(u8, 9), local.hour);
        if (prev) |p| {
            const gap = start.seconds() - p;
            if (gap == 82_800) saw_short_gap = true else try testing.expectEqual(@as(i64, 86_400), gap);
        }
        prev = start.seconds();
    }
    try testing.expect(saw_short_gap); // the spring-forward really shortened one real-time gap
}

test "a weekly event steps seven days and occupies each occurrence" {
    var e = eastern9am(2026, 7, 1);
    e.repeat = .{ .frequency = .weekly, .count = 3 };
    try testing.expectEqual(@as(usize, 3), e.count());
    // The third occurrence is fourteen days after the first, same local time.
    const first = zone.us_eastern.instantToLocal(e.occurrenceStart(0).?);
    const third = zone.us_eastern.instantToLocal(e.occurrenceStart(2).?);
    try testing.expectEqual(first.hour, third.hour);
    try testing.expectEqual(@as(u8, 15), third.date.day); // Jul 1 + 14
}
