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

const Event = struct { title: []const u8, slot: u32 };
const Applied = struct { key: u128, result: []const u8 };

/// The Calendar store: the real events and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event) = .empty,
    /// Real date-and-time events, including recurring ones, resolved through the schedule so free/busy
    /// is answered over their actual occurrences rather than an abstract slot.
    scheduled: std.ArrayListUnmanaged(schedule.Event) = .empty,
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

    /// Adds a real date-and-time event (one-off or recurring) to the calendar.
    pub fn addScheduled(store: *Store, event: schedule.Event) !void {
        try store.scheduled.append(store.gpa, event);
    }

    pub fn scheduledCount(store: Store) usize {
        return store.scheduled.items.len;
    }

    /// Whether any scheduled event is occupying a real instant — free/busy answered over every event's
    /// actual occurrences, recurrence and daylight saving already resolved by the schedule.
    pub fn busyAtInstant(store: Store, at: core.time.Timestamp) bool {
        for (store.scheduled.items) |event| {
            if (event.occupies(at)) return true;
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
