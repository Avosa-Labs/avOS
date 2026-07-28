//! The Photos domain: the person's real photo library — the photos, the albums they are filed into,
//! which are favourites — and the one consequential act over it, sharing a photo, which leaves the
//! device and so is held for the person.
//!
//! This is the "one domain" both doors reach. Importing a photo, filing it into an album, and marking
//! a favourite are ordinary local changes; listing and viewing are silent. Sharing is the single act
//! that reaches outside the device, so the frame holds an agent's share for the person and applies it
//! exactly once by key — an approval after a restart or a double tap shares once. An agent organising
//! the library runs the identical code the person's finger runs, over the same photos.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A photo in the library: its stable id, the album it is filed into (if any), and whether it is a
/// favourite. The bytes live on the device; the domain holds only what organises them.
const Photo = struct {
    id: []const u8,
    album: ?[]const u8 = null,
    favorite: bool = false,
};

const Applied = struct { key: u128, result: []const u8 };

/// The Photos store: the real library and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    photos: std.ArrayListUnmanaged(Photo) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.photos.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.photos.items.len;
    }

    fn find(store: *Store, id: []const u8) ?*Photo {
        for (store.photos.items) |*photo| {
            if (std.mem.eql(u8, photo.id, id)) return photo;
        }
        return null;
    }

    /// How many photos are filed into a named album — the count an album view shows.
    pub fn albumCount(store: Store, album: []const u8) usize {
        var n: usize = 0;
        for (store.photos.items) |photo| {
            if (photo.album) |a| {
                if (std.mem.eql(u8, a, album)) n += 1;
            }
        }
        return n;
    }

    /// Whether a photo is marked a favourite.
    pub fn isFavorite(store: *Store, id: []const u8) bool {
        return if (store.find(id)) |photo| photo.favorite else false;
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

    /// The one entry point both doors reach. `args` is a photo id, or "id@album" for filing.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "photo.list")) return .{ .ok = "listed" };
        if (std.mem.eql(u8, op, "photo.view")) {
            return .{ .ok = if (store.find(input.args) != null) "viewed" else "missing" };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "photo.import")) {
            if (input.args.len == 0) return .failed;
            if (store.find(input.args) == null) {
                store.photos.append(store.gpa, .{ .id = input.args }) catch return .failed;
            }
            return store.commit(key, "imported");
        }
        if (std.mem.eql(u8, op, "photo.favorite")) {
            const photo = store.find(input.args) orelse return .failed;
            photo.favorite = true;
            return store.commit(key, "favorited");
        }
        if (std.mem.eql(u8, op, "photo.album")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const photo = store.find(input.args[0..at]) orelse return .failed;
            photo.album = input.args[at + 1 ..];
            return store.commit(key, "filed");
        }
        // Consequential: sharing leaves the device. The frame has already held it for the person; the
        // domain applies it once and records the key so a re-drive returns the first result.
        if (std.mem.eql(u8, op, "photo.share")) {
            if (store.find(input.args) == null) return .failed;
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

fn importPhoto(store: *Store, id: []const u8, key: u128) void {
    _ = Store.execute(store, .{ .operation = "photo.import", .args = id }, agent(), key);
}

test "importing adds a photo once; a repeat id is not a second photo" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    importPhoto(&store, "p1", 1);
    importPhoto(&store, "p1", 2); // same id, different key: still one photo
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "filing photos into an album counts them, and favouriting marks one" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    importPhoto(&store, "p1", 1);
    importPhoto(&store, "p2", 2);
    _ = Store.execute(&store, .{ .operation = "photo.album", .args = "p1@Trip" }, agent(), 3);
    _ = Store.execute(&store, .{ .operation = "photo.album", .args = "p2@Trip" }, agent(), 4);
    try testing.expectEqual(@as(usize, 2), store.albumCount("Trip"));

    try testing.expect(!store.isFavorite("p1"));
    _ = Store.execute(&store, .{ .operation = "photo.favorite", .args = "p1" }, agent(), 5);
    try testing.expect(store.isFavorite("p1"));
}

test "sharing is the one consequential act, applied exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    importPhoto(&store, "p1", 1);
    const first = Store.execute(&store, .{ .operation = "photo.share", .args = "p1" }, agent(), 9);
    const again = Store.execute(&store, .{ .operation = "photo.share", .args = "p1" }, agent(), 9); // same key
    switch (first) {
        .ok => |t| try testing.expectEqualStrings("shared", t),
        .failed => return error.TestUnexpectedResult,
    }
    switch (again) {
        .ok => |t| try testing.expectEqualStrings("shared", t), // the first result, not a second share
        .failed => return error.TestUnexpectedResult,
    }
}
