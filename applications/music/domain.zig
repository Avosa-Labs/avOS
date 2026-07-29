//! The Music domain: the person's real library of tracks, what is playing now, and the queue of what
//! plays next — all on the device, reaching nothing outside it.
//!
//! This is the "one domain" both doors reach. It holds the library, the track playing now, and the
//! queue. Listing the library and reading what is playing are silent; playing a track and queueing one
//! are ordinary local changes an agent may make and the person hears. Nothing here is consequential —
//! playing music reaches nothing beyond the device — so no operation is held; Music is a fully-local
//! media app that still runs the whole frame. An agent building a queue runs the identical code the
//! person's finger runs, over the same library.
//!
//! This module is the app's real logic and storage; the gating and recording are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

const Track = struct { title: []const u8, artist: []const u8 };
const Applied = struct { key: u128, result: []const u8 };

/// The Music store: the library, the index of the track playing now, the queue, and the record of
/// applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    library: std.ArrayListUnmanaged(Track) = .empty,
    queue: std.ArrayListUnmanaged(usize) = .empty,
    now_playing: ?usize = null,
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.library.deinit(store.gpa);
        store.queue.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.library.items.len;
    }

    pub fn queueLength(store: Store) usize {
        return store.queue.items.len;
    }

    /// Adds a track to the library — how the library is populated, outside the play path.
    pub fn addTrack(store: *Store, title: []const u8, artist: []const u8) !void {
        try store.library.append(store.gpa, .{ .title = title, .artist = artist });
    }

    fn indexOf(store: *Store, title: []const u8) ?usize {
        for (store.library.items, 0..) |track, i| {
            if (std.mem.eql(u8, track.title, title)) return i;
        }
        return null;
    }

    /// The title of the track playing now, or null if nothing is playing.
    pub fn nowPlayingTitle(store: *Store) ?[]const u8 {
        const idx = store.now_playing orelse return null;
        return store.library.items[idx].title;
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

    /// The one entry point both doors reach. `args` is a track title.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "music.list")) return .{ .ok = "listed" };
        if (std.mem.eql(u8, op, "music.now_playing")) {
            return .{ .ok = if (store.nowPlayingTitle() != null) "playing" else "stopped" };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "music.play")) {
            const idx = store.indexOf(input.args) orelse return .failed;
            store.now_playing = idx;
            return store.commit(key, "playing");
        }
        if (std.mem.eql(u8, op, "music.queue")) {
            const idx = store.indexOf(input.args) orelse return .failed;
            store.queue.append(store.gpa, idx) catch return .failed;
            return store.commit(key, "queued");
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

test "playing a track sets what is playing now; a missing track fails" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.addTrack("Nightcall", "Kavinsky");
    try store.addTrack("Midnight City", "M83");
    try testing.expect(store.nowPlayingTitle() == null); // nothing playing yet
    _ = Store.execute(&store, .{ .operation = "music.play", .args = "Midnight City" }, agent(), 1);
    try testing.expectEqualStrings("Midnight City", store.nowPlayingTitle().?);
    // Playing a track not in the library fails.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "music.play", .args = "Unknown" }, agent(), 2));
}

test "queueing adds tracks to play next, exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.addTrack("Nightcall", "Kavinsky");
    try store.addTrack("Midnight City", "M83");
    _ = Store.execute(&store, .{ .operation = "music.queue", .args = "Nightcall" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "music.queue", .args = "Nightcall" }, agent(), 1); // same key: no second enqueue
    try testing.expectEqual(@as(usize, 1), store.queueLength());
    _ = Store.execute(&store, .{ .operation = "music.queue", .args = "Midnight City" }, agent(), 2);
    try testing.expectEqual(@as(usize, 2), store.queueLength());
}
