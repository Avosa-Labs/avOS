//! The Calendar domain: real events a person and their agents schedule and query, with
//! a free/busy answer computed from the actual events.
//!
//! This is the "one domain" both doors reach, holding actual events. Reading lists them;
//! a free/busy query answers whether a slot is taken by any real event, never what fills
//! it; adding and editing change the calendar; inviting reaches other people and is held
//! for the person. Every change is exactly-once by key. An agent scheduling and a person
//! scheduling run the identical code over the same events.
//!
//! This module is the app's real logic and storage; the gating and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
// The platform slice (instants) reached through the frame — an app file may not import the core
// plane directly, so the framework re-exports what free/busy over real events needs.
const core = framework.platform;
const schedule = @import("schedule.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// What a free/busy query is allowed to learn about a slot: only whether it is taken.
pub const Availability = enum { free, busy };

/// A focus block: an inclusive run of consecutive busy slots, all committed time.
pub const FocusBlock = struct { start: u32, end: u32 };

/// The local calendar an event belongs to when none is named — a person's default calendar.
pub const default_calendar = "Personal";

/// A single occurrence of an event landing inside a queried window: which event produced it, the
/// local calendar it belongs to, and the instant it starts. This is the unit a month, week, day, or
/// agenda view is built from — one row per real instance, recurring events already expanded.
pub const Occurrence = struct {
    event_index: usize,
    calendar_name: []const u8,
    start: core.time.Timestamp,
};

/// A reminder due to fire inside a queried window: the occurrence it belongs to, the instant the
/// reminder itself fires (the occurrence start less the event's lead time), and the occurrence start.
pub const Reminder = struct {
    event_index: usize,
    calendar_name: []const u8,
    fires_at: core.time.Timestamp,
    occurrence_start: core.time.Timestamp,
};

const Event = struct { title: []const u8, slot: u32 };
const Applied = struct { key: u128, result: []const u8 };

/// A scheduled event together with the calendar it lives on and its reminder lead time in minutes
/// (zero meaning no reminder) — the metadata a full calendar carries beside the bare schedule.
const Scheduled = struct {
    event: schedule.Event,
    calendar_name: []const u8,
    lead_minutes: u32,
};

/// The Calendar store: the real events and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event) = .empty,
    /// Real date-and-time events, including recurring ones, each on a named local calendar and with
    /// an optional reminder; free/busy and window expansion read their actual occurrences through the
    /// schedule rather than an abstract slot.
    scheduled: std.ArrayListUnmanaged(Scheduled) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.events.deinit(store.gpa);
        store.scheduled.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.events.items.len;
    }

    /// Adds a real date-and-time event (one-off or recurring) to the calendar, on the default
    /// calendar and with no reminder.
    pub fn addScheduled(store: *Store, event: schedule.Event) !void {
        try store.addScheduledIn(event, default_calendar, 0);
    }

    /// Adds a real date-and-time event on a named local calendar, with a reminder `lead_minutes`
    /// before each occurrence (zero for no reminder).
    pub fn addScheduledIn(store: *Store, event: schedule.Event, calendar_name: []const u8, lead_minutes: u32) !void {
        try store.scheduled.append(store.gpa, .{ .event = event, .calendar_name = calendar_name, .lead_minutes = lead_minutes });
    }

    pub fn scheduledCount(store: Store) usize {
        return store.scheduled.items.len;
    }

    /// Whether any scheduled event is occupying a real instant — free/busy answered over every event's
    /// actual occurrences, recurrence and daylight saving already resolved by the schedule.
    pub fn busyAtInstant(store: Store, at: core.time.Timestamp) bool {
        for (store.scheduled.items) |entry| {
            if (entry.event.occupies(at)) return true;
        }
        return false;
    }

    /// The real availability of a slot: busy if any event occupies it.
    pub fn availabilityOf(store: Store, slot: u32) Availability {
        for (store.events.items) |event| {
            if (event.slot == slot) return .busy;
        }
        return .free;
    }

    /// The day arranged into focus blocks: the maximal runs of consecutive busy slots, derived
    /// from the real events. This is the view the person and a reading agent see — where time is
    /// already committed — rather than a flat list of events; it is computed, never stored, so it
    /// can never drift from the events. Blocks are written into `out` in slot order.
    pub fn focusBlocks(store: Store, out: []FocusBlock) []const FocusBlock {
        var max_slot: u32 = 0;
        var any = false;
        for (store.events.items) |event| {
            if (!any or event.slot > max_slot) max_slot = event.slot;
            any = true;
        }
        if (!any) return out[0..0];

        var n: usize = 0;
        var in_block = false;
        var block_start: u32 = 0;
        var slot: u32 = 0;
        // Scan one past the last slot so a block ending at max_slot is closed.
        while (slot <= max_slot + 1) : (slot += 1) {
            const busy = slot <= max_slot and store.availabilityOf(slot) == .busy;
            if (busy and !in_block) {
                in_block = true;
                block_start = slot;
            } else if (!busy and in_block) {
                if (n < out.len) {
                    out[n] = .{ .start = block_start, .end = slot - 1 };
                    n += 1;
                }
                in_block = false;
            }
        }
        return out[0..n];
    }

    /// Every occurrence of every event whose start falls in the half-open window [from, to), the
    /// recurring events expanded — the read a month, week, day, or agenda view is drawn from. With a
    /// `filter`, only events on that named calendar are expanded; a null filter takes them all.
    /// Occurrences are written into `out` in chronological order, capped at `out.len`.
    ///
    /// The walk is bounded by the window, not the index space: each event jumps straight to its first
    /// in-window occurrence via `firstIndexAtOrAfter` (period arithmetic, not a scan from zero) and
    /// stops as soon as an occurrence passes `to`. So an event that began years before the window,
    /// or repeats thousands of times, is still visited only for the occurrences actually in range,
    /// making the whole expansion O(events + occurrences in the window).
    pub fn occurrencesInWindow(store: Store, from: core.time.Timestamp, to: core.time.Timestamp, filter: ?[]const u8, out: []Occurrence) []const Occurrence {
        var n: usize = 0;
        for (store.scheduled.items, 0..) |entry, event_index| {
            if (filter) |name| {
                if (!std.mem.eql(u8, name, entry.calendar_name)) continue;
            }
            var index = entry.event.firstIndexAtOrAfter(from);
            while (n < out.len) : (index += 1) {
                const start = entry.event.occurrenceStart(index) orelse break;
                if (start.seconds() >= to.seconds()) break;
                // The first index is stepped back for daylight-saving slack, so an occurrence before
                // the window can appear here; skip it without emitting.
                if (start.seconds() < from.seconds()) continue;
                out[n] = .{ .event_index = event_index, .calendar_name = entry.calendar_name, .start = start };
                n += 1;
            }
        }
        std.mem.sort(Occurrence, out[0..n], {}, lessOccurrence);
        return out[0..n];
    }

    /// Every reminder due to fire in the half-open window [from, to): for each event carrying a
    /// reminder, the occurrences whose fire time (start less the lead) lands in the window. Because a
    /// reminder fires the lead before its occurrence, the occurrences whose reminder is in [from, to)
    /// are exactly those starting in [from + lead, to + lead) — the same window shifted by the lead,
    /// walked with the same window-bounded arithmetic as the expansion. Filtered by calendar the same
    /// way; written in fire-time order, capped at `out.len`.
    pub fn remindersInWindow(store: Store, from: core.time.Timestamp, to: core.time.Timestamp, filter: ?[]const u8, out: []Reminder) []const Reminder {
        var n: usize = 0;
        for (store.scheduled.items, 0..) |entry, event_index| {
            if (entry.lead_minutes == 0) continue;
            if (filter) |name| {
                if (!std.mem.eql(u8, name, entry.calendar_name)) continue;
            }
            const lead: i64 = @as(i64, entry.lead_minutes) * 60;
            const from_start = from.seconds() + lead;
            const to_start = to.seconds() + lead;
            var index = entry.event.firstIndexAtOrAfter(core.time.Timestamp.fromSeconds(from_start));
            while (n < out.len) : (index += 1) {
                const start = entry.event.occurrenceStart(index) orelse break;
                if (start.seconds() >= to_start) break;
                if (start.seconds() < from_start) continue;
                out[n] = .{
                    .event_index = event_index,
                    .calendar_name = entry.calendar_name,
                    .fires_at = core.time.Timestamp.fromSeconds(start.seconds() - lead),
                    .occurrence_start = start,
                };
                n += 1;
            }
        }
        std.mem.sort(Reminder, out[0..n], {}, lessReminder);
        return out[0..n];
    }

    fn lessOccurrence(_: void, a: Occurrence, b: Occurrence) bool {
        return a.start.seconds() < b.start.seconds();
    }

    fn lessReminder(_: void, a: Reminder, b: Reminder) bool {
        return a.fires_at.seconds() < b.fires_at.seconds();
    }

    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |entry| {
            if (entry.key == key) return entry.result;
        }
        return null;
    }

    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }

    /// The one entry point both doors reach. `args` is "title@slot" for an add, or a
    /// slot number for a free/busy query.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "calendar.read")) return .{ .ok = "read" };
        if (std.mem.eql(u8, op, "calendar.freebusy")) {
            const slot = std.fmt.parseInt(u32, input.args, 10) catch return .failed;
            return .{ .ok = if (store.availabilityOf(slot) == .busy) "busy" else "free" };
        }
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "calendar.add")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const title = input.args[0..at];
            const slot = std.fmt.parseInt(u32, input.args[at + 1 ..], 10) catch return .failed;
            store.events.append(store.gpa, .{ .title = title, .slot = slot }) catch return .failed;
            return store.commit(key, "added");
        }
        if (std.mem.eql(u8, op, "calendar.edit")) return store.commit(key, "edited");
        if (std.mem.eql(u8, op, "calendar.invite")) return store.commit(key, "invited");
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

const testing = std.testing;
fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

test "a free/busy query is computed from the real events" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try testing.expectEqual(Availability.free, store.availabilityOf(9));
    _ = Store.execute(&store, .{ .operation = "calendar.add", .args = "Standup@9" }, agent(), 1);
    try testing.expectEqual(Availability.busy, store.availabilityOf(9));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "adding an event is exactly-once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "calendar.add", .args = "Lunch@12" }, agent(), 5);
    _ = Store.execute(&store, .{ .operation = "calendar.add", .args = "Lunch@12" }, agent(), 5);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "the day arranges into focus blocks: maximal runs of consecutive busy slots" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // Busy at 2, 3, and 5 — a two-slot block, then a one-slot block, a free slot between them.
    _ = Store.execute(&store, .{ .operation = "calendar.add", .args = "Design@2" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "calendar.add", .args = "Review@3" }, agent(), 2);
    _ = Store.execute(&store, .{ .operation = "calendar.add", .args = "Ship@5" }, agent(), 3);

    var buffer: [8]FocusBlock = undefined;
    const blocks = store.focusBlocks(&buffer);
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expectEqual(FocusBlock{ .start = 2, .end = 3 }, blocks[0]);
    try testing.expectEqual(FocusBlock{ .start = 5, .end = 5 }, blocks[1]);
}

test "an empty calendar has no focus blocks" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    var buffer: [8]FocusBlock = undefined;
    try testing.expectEqual(@as(usize, 0), store.focusBlocks(&buffer).len);
}

test "a real datetime event makes the calendar busy at its occurrences" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // A daily 09:00 eastern meeting, one hour, for three days.
    const event = schedule.Event{
        .start = .{ .date = .{ .year = 2026, .month = 7, .day = 1 }, .hour = 9 },
        .zone = core.zone.us_eastern,
        .duration_seconds = 3600,
        .repeat = .{ .frequency = .daily, .count = 3 },
    };
    try store.addScheduled(event);
    try testing.expectEqual(@as(usize, 1), store.scheduledCount());
    // Busy at the first occurrence's start; free two hours after it ends.
    const start = event.occurrenceStart(0).?;
    try testing.expect(store.busyAtInstant(start));
    try testing.expect(!store.busyAtInstant(core.time.Timestamp.fromSeconds(start.seconds() + 2 * 3600)));
    // Busy at the third day's occurrence too — the recurrence is resolved.
    const third = event.occurrenceStart(2).?;
    try testing.expect(store.busyAtInstant(third));
}

fn easternMidnight(year: i32, month: u8, day: u8) core.time.Timestamp {
    return core.zone.us_eastern.localToInstant(.{ .date = .{ .year = year, .month = month, .day = day }, .hour = 0 });
}

fn daily9am(year: i32, month: u8, day: u8, count: u32) schedule.Event {
    return .{
        .start = .{ .date = .{ .year = year, .month = month, .day = day }, .hour = 9 },
        .zone = core.zone.us_eastern,
        .duration_seconds = 3600,
        .repeat = .{ .frequency = .daily, .count = count },
    };
}

test "a daily 09:00 expands to exactly its in-window occurrences, each 09:00 local across a DST boundary" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // Runs from Mar 6 2026 across the Mar 8 spring-forward; the window is the seven days Mar 6..12.
    try store.addScheduled(daily9am(2026, 3, 6, 30));
    const from = easternMidnight(2026, 3, 6);
    const to = easternMidnight(2026, 3, 13);

    var buffer: [16]Occurrence = undefined;
    const got = store.occurrencesInWindow(from, to, null, &buffer);
    try testing.expectEqual(@as(usize, 7), got.len);
    // Each occurrence reads back as 09:00 local on its own day, the instant absorbing the DST shift,
    // and the occurrences are in chronological order over the days Mar 6..12.
    var expected_day: u8 = 6;
    var prev: i64 = std.math.minInt(i64);
    for (got) |occurrence| {
        const local = core.zone.us_eastern.instantToLocal(occurrence.start);
        try testing.expectEqual(@as(u8, 9), local.hour);
        try testing.expectEqual(expected_day, local.date.day);
        try testing.expect(occurrence.start.seconds() > prev);
        prev = occurrence.start.seconds();
        expected_day += 1;
    }
}

test "a one-off event appears only when its single start is in the window" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // A single meeting at 09:00 on Jul 15.
    try store.addScheduled(.{
        .start = .{ .date = .{ .year = 2026, .month = 7, .day = 15 }, .hour = 9 },
        .zone = core.zone.us_eastern,
        .duration_seconds = 3600,
    });
    var buffer: [8]Occurrence = undefined;
    // A window over Jul 15 contains it; a window over the week before does not.
    try testing.expectEqual(@as(usize, 1), store.occurrencesInWindow(easternMidnight(2026, 7, 15), easternMidnight(2026, 7, 16), null, &buffer).len);
    try testing.expectEqual(@as(usize, 0), store.occurrencesInWindow(easternMidnight(2026, 7, 1), easternMidnight(2026, 7, 8), null, &buffer).len);
}

test "an event starting long before the window yields only its in-window occurrences" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // A daily 09:00 running since 2000 — the walk must reach 2026 by period arithmetic, not by
    // visiting the ~9,600 occurrences in between.
    try store.addScheduled(daily9am(2000, 1, 1, 20_000));
    var buffer: [8]Occurrence = undefined;
    const got = store.occurrencesInWindow(easternMidnight(2026, 7, 15), easternMidnight(2026, 7, 16), null, &buffer);
    try testing.expectEqual(@as(usize, 1), got.len);
    const local = core.zone.us_eastern.instantToLocal(got[0].start);
    try testing.expectEqual(@as(u8, 9), local.hour);
    try testing.expectEqual(@as(u8, 15), local.date.day);
}

test "reminders fire the lead before each occurrence and are returned in range" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // A daily 09:00 with a 30-minute reminder, and a second event with no reminder that must never appear.
    try store.addScheduledIn(daily9am(2026, 7, 1, 5), "Personal", 30);
    try store.addScheduled(daily9am(2026, 7, 1, 5)); // lead 0 — no reminder
    // Reminders fire at 08:30 on Jul 1 and Jul 2; the Jul 3 08:30 reminder is past the window end.
    var buffer: [8]Reminder = undefined;
    const got = store.remindersInWindow(easternMidnight(2026, 7, 1), easternMidnight(2026, 7, 3), null, &buffer);
    try testing.expectEqual(@as(usize, 2), got.len);
    for (got) |reminder| {
        // The reminder fires exactly 30 minutes before its occurrence.
        try testing.expectEqual(reminder.occurrence_start.seconds() - 30 * 60, reminder.fires_at.seconds());
        const at_start = core.zone.us_eastern.instantToLocal(reminder.occurrence_start);
        const at_fire = core.zone.us_eastern.instantToLocal(reminder.fires_at);
        try testing.expectEqual(@as(u8, 9), at_start.hour);
        try testing.expectEqual(@as(u8, 8), at_fire.hour);
        try testing.expectEqual(@as(u8, 30), at_fire.minute);
    }
}

test "expansion filters by local calendar, and a null filter takes them all" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // A work meeting and a personal lunch on the same day, on different calendars.
    try store.addScheduledIn(.{
        .start = .{ .date = .{ .year = 2026, .month = 7, .day = 2 }, .hour = 10 },
        .zone = core.zone.us_eastern,
        .duration_seconds = 3600,
    }, "Work", 0);
    try store.addScheduledIn(.{
        .start = .{ .date = .{ .year = 2026, .month = 7, .day = 2 }, .hour = 12 },
        .zone = core.zone.us_eastern,
        .duration_seconds = 3600,
    }, "Personal", 0);
    const from = easternMidnight(2026, 7, 2);
    const to = easternMidnight(2026, 7, 3);

    var buffer: [8]Occurrence = undefined;
    // Unfiltered: both. Filtered to Work: only the work meeting.
    try testing.expectEqual(@as(usize, 2), store.occurrencesInWindow(from, to, null, &buffer).len);
    const work = store.occurrencesInWindow(from, to, "Work", &buffer);
    try testing.expectEqual(@as(usize, 1), work.len);
    try testing.expectEqualStrings("Work", work[0].calendar_name);
    const personal = store.occurrencesInWindow(from, to, "Personal", &buffer);
    try testing.expectEqual(@as(usize, 1), personal.len);
    try testing.expectEqualStrings("Personal", personal[0].calendar_name);
}
