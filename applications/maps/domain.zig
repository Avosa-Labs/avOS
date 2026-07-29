//! The Maps domain: the places a person saves and the one act that reaches off the device — sharing a
//! location — which is held for the person.
//!
//! This is the "one domain" both doors reach. It holds the person's saved places, each with a
//! coordinate, and answers a real question over them: the distance between two of them, computed on the
//! device from their coordinates, never a call to anyone. Listing places and reading a distance are
//! silent; saving a place is an ordinary local change. Sharing a location sends where the person is (or
//! a saved place) to someone else, so it leaves the device and is held for the person, applied exactly
//! once by key. An agent planning a route runs the identical code the person's finger runs, over the
//! same places.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A saved place: a name and an integer grid coordinate. Integer coordinates keep the distance exact
/// and deterministic, with no floating-point in the domain.
const Place = struct { name: []const u8, x: i32, y: i32 };
const Applied = struct { key: u128, result: []const u8 };

/// The Maps store: the saved places and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    places: std.ArrayListUnmanaged(Place) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [16]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.places.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.places.items.len;
    }

    fn find(store: Store, name: []const u8) ?Place {
        for (store.places.items) |place| {
            if (std.mem.eql(u8, place.name, name)) return place;
        }
        return null;
    }

    /// The grid distance between two saved places — the sum of the coordinate differences, computed on
    /// the device. Null if either place is not saved.
    pub fn distanceBetween(store: Store, from: []const u8, to: []const u8) ?u32 {
        const a = store.find(from) orelse return null;
        const b = store.find(to) orelse return null;
        const dx = @abs(a.x - b.x);
        const dy = @abs(a.y - b.y);
        return @intCast(dx + dy);
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

    fn parsePlace(args: []const u8) ?Place {
        const at = std.mem.indexOfScalar(u8, args, '@') orelse return null;
        const name = args[0..at];
        const comma = std.mem.indexOfScalar(u8, args[at + 1 ..], ',') orelse return null;
        const x = std.fmt.parseInt(i32, args[at + 1 .. at + 1 + comma], 10) catch return null;
        const y = std.fmt.parseInt(i32, args[at + 1 + comma + 1 ..], 10) catch return null;
        if (name.len == 0) return null;
        return .{ .name = name, .x = x, .y = y };
    }

    /// The one entry point both doors reach. For a save `args` is "name@x,y"; for a distance it is
    /// "from@to"; for a share it is a place name.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "maps.list")) return .{ .ok = "listed" };
        if (std.mem.eql(u8, op, "maps.distance")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const d = store.distanceBetween(input.args[0..at], input.args[at + 1 ..]) orelse return .failed;
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{d}) catch return .failed;
            return .{ .ok = text };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "maps.save")) {
            const place = parsePlace(input.args) orelse return .failed;
            if (store.find(place.name) != null) return store.commit(key, "saved"); // already saved, idempotent
            store.places.append(store.gpa, place) catch return .failed;
            return store.commit(key, "saved");
        }
        // Consequential: sharing a location sends where the person is to someone else. The frame has
        // already held it for the person; the domain applies it once and records the key.
        if (std.mem.eql(u8, op, "maps.share_location")) {
            if (store.find(input.args) == null) return .failed; // can only share a place that exists
            return store.commit(key, "shared");
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

fn save(store: *Store, args: []const u8, key: u128) void {
    _ = Store.execute(store, .{ .operation = "maps.save", .args = args }, agent(), key);
}

test "saving places and reading the distance between them is a real on-device computation" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    save(&store, "Home@0,0", 1);
    save(&store, "Home@9,9", 2); // same name, different key: still one place
    save(&store, "Work@3,4", 3);
    try testing.expectEqual(@as(usize, 2), store.count());
    // Grid distance from (0,0) to (3,4) is 7.
    try testing.expectEqualStrings("7", Store.execute(&store, .{ .operation = "maps.distance", .args = "Home@Work" }, agent(), 0).ok);
    // A distance to an unsaved place fails.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "maps.distance", .args = "Home@Gym" }, agent(), 0));
}

test "sharing a location is the one consequential act, applied exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    save(&store, "Home@0,0", 1);
    const first = Store.execute(&store, .{ .operation = "maps.share_location", .args = "Home" }, agent(), 9);
    const again = Store.execute(&store, .{ .operation = "maps.share_location", .args = "Home" }, agent(), 9); // same key
    try testing.expectEqualStrings("shared", first.ok);
    try testing.expectEqualStrings("shared", again.ok); // the first result, not a second share
    // Sharing a place that is not saved fails.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "maps.share_location", .args = "Nowhere" }, agent(), 10));
}
