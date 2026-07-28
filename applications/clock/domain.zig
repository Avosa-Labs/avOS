//! The Clock domain: the world clocks a person keeps and the local time each reads at a given
//! instant, computed from the real zone rules — standard offset and daylight saving — rather than a
//! stored string that would drift the moment the clocks change.
//!
//! This is the "one domain" both doors reach. It holds the saved world clocks; a time query resolves
//! a UTC instant into a zone's wall-clock time through the same civil-and-zone arithmetic the calendar
//! trusts, so a clock added for a place shows the correct local time across a daylight-saving boundary
//! without anyone re-entering it. Listing and reading are silent; adding and removing a world clock are
//! ordinary local changes. Nothing here is consequential — Clock is a light, read-mostly app that still
//! runs the whole frame, and it is the app that proves the time foundation end to end.
//!
//! This module is the app's real logic and storage; the gating and recording are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
// The platform slice (civil dates, zones, instants) reached through the frame — an app file may not
// import the core plane directly, so the framework re-exports what the clock needs.
const core = framework.platform;

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A saved world clock: a person's label for a place and the real zone its local time is read through.
pub const WorldClock = struct {
    label: []const u8,
    zone: core.zone.TimeZone,
};

const Applied = struct { key: u128, result: []const u8 };

/// The Clock store: the saved world clocks and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    clocks: std.ArrayListUnmanaged(WorldClock) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.clocks.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.clocks.items.len;
    }

    /// Adds a world clock with its real zone. The typed entry point tests and callers with a full
    /// zone (daylight-saving rule and all) use; the text door adds a fixed-offset zone by hours.
    pub fn addClock(store: *Store, label: []const u8, zone: core.zone.TimeZone) !void {
        try store.clocks.append(store.gpa, .{ .label = label, .zone = zone });
    }

    fn zoneOf(store: Store, label: []const u8) ?core.zone.TimeZone {
        for (store.clocks.items) |clock| {
            if (std.mem.eql(u8, clock.label, label)) return clock.zone;
        }
        return null;
    }

    /// The local wall-clock time a saved clock reads at a UTC instant, resolved through the zone's
    /// offset and daylight-saving rule — so it is correct on either side of a transition. Null if no
    /// clock carries that label.
    pub fn localTimeAt(store: Store, label: []const u8, at: core.time.Timestamp) ?core.civil.DateTime {
        const zone = store.zoneOf(label) orelse return null;
        return zone.instantToLocal(at);
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

    /// The one entry point both doors reach. For a time read `args` is "label@<instant_seconds>";
    /// for an add it is "label@<offset_hours>"; for a remove it is the label.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "clock.list")) return .{ .ok = "listed" };
        if (std.mem.eql(u8, op, "clock.time")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const seconds = std.fmt.parseInt(i64, input.args[at + 1 ..], 10) catch return .failed;
            const local = store.localTimeAt(input.args[0..at], core.time.Timestamp.fromSeconds(seconds)) orelse return .failed;
            const text = std.fmt.bufPrint(&store.reply, "{d:0>2}:{d:0>2}", .{ local.hour, local.minute }) catch return .failed;
            return .{ .ok = text };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "clock.add")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const hours = std.fmt.parseInt(i32, input.args[at + 1 ..], 10) catch return .failed;
            store.addClock(input.args[0..at], .{ .standard_offset_seconds = hours * 3600 }) catch return .failed;
            return store.commit(key, "added");
        }
        if (std.mem.eql(u8, op, "clock.remove")) {
            for (store.clocks.items, 0..) |clock, i| {
                if (std.mem.eql(u8, clock.label, input.args)) {
                    _ = store.clocks.orderedRemove(i);
                    break;
                }
            }
            return store.commit(key, "removed");
        }
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

// --- Tests ---

const testing = std.testing;

fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

test "a world clock reads its zone's local time at an instant" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // 2026-07-15 16:00:00 UTC. Eastern is on daylight saving in July (UTC−4), so it reads 12:00.
    try store.addClock("New York", core.zone.us_eastern);
    const utc_noon_plus_4 = core.civil.DateTime{ .date = .{ .year = 2026, .month = 7, .day = 15 }, .hour = 16 };
    const local = store.localTimeAt("New York", utc_noon_plus_4.toTimestamp()).?;
    try testing.expectEqual(@as(u8, 12), local.hour);
    try testing.expect(store.localTimeAt("Nowhere", utc_noon_plus_4.toTimestamp()) == null);
}

test "the same clock reads correctly on both sides of a daylight-saving change" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.addClock("New York", core.zone.us_eastern);
    // 16:00 UTC in January is standard time (UTC−5) → 11:00 local; in July it is DST (UTC−4) → 12:00.
    const winter = core.civil.DateTime{ .date = .{ .year = 2026, .month = 1, .day = 15 }, .hour = 16 };
    const summer = core.civil.DateTime{ .date = .{ .year = 2026, .month = 7, .day = 15 }, .hour = 16 };
    try testing.expectEqual(@as(u8, 11), store.localTimeAt("New York", winter.toTimestamp()).?.hour);
    try testing.expectEqual(@as(u8, 12), store.localTimeAt("New York", summer.toTimestamp()).?.hour);
}

test "adding a fixed-offset clock through the text door, and reading its time" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "clock.add", .args = "Tokyo@9" }, agent(), 1);
    try testing.expectEqual(@as(usize, 1), store.count());
    // 2026-07-15 00:00:00 UTC reads 09:00 in a UTC+9 zone.
    const midnight = core.civil.DateTime{ .date = .{ .year = 2026, .month = 7, .day = 15 }, .hour = 0 };
    var args_buf: [32]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "Tokyo@{d}", .{midnight.toTimestamp().seconds()}) catch unreachable;
    const result = Store.execute(&store, .{ .operation = "clock.time", .args = args }, agent(), 0);
    switch (result) {
        .ok => |text| try testing.expectEqualStrings("09:00", text),
        .failed => return error.TestUnexpectedResult,
    }
}

test "adding a clock is exactly-once by key, and removing one takes it off" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "clock.add", .args = "Tokyo@9" }, agent(), 7);
    _ = Store.execute(&store, .{ .operation = "clock.add", .args = "Tokyo@9" }, agent(), 7); // same key: no second clock
    try testing.expectEqual(@as(usize, 1), store.count());
    _ = Store.execute(&store, .{ .operation = "clock.remove", .args = "Tokyo" }, agent(), 8);
    try testing.expectEqual(@as(usize, 0), store.count());
}
