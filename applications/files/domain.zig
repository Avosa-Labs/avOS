//! The Files domain: a real file tree a person and their agents browse and organize —
//! entries with paths, listed, opened, edited, moved, shared, and deleted for real.
//!
//! This is the "one domain" both doors reach, holding actual entries: each has a path
//! and whether it is a folder. Listing a directory returns the entries under it; opening
//! reads one; editing, moving, and deleting change the tree; sharing sends a file
//! outside the device and is held for the person. Every path is confined to the grant —
//! a path that climbs out of the granted root is refused before it touches anything — and
//! every change is exactly-once by the operation's key. An agent tidying files and a
//! person doing the same run the identical code over the same tree.
//!
//! This module is the app's real logic and storage; the gating, recording, and approval
//! around it are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

const Entry = struct { path: []const u8, is_dir: bool };
const Applied = struct { key: u128, result: []const u8 };

/// Whether a relative path stays within the granted root — never absolute, never
/// climbing above it.
pub fn withinGrant(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var depth: i32 = 0;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            depth -= 1;
            if (depth < 0) return false;
        } else depth += 1;
    }
    return true;
}

/// The Files store: the real entries in the tree and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.entries.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    /// Seeds the tree with an entry, for the surface and tests to populate it.
    pub fn add(store: *Store, path: []const u8, is_dir: bool) !void {
        try store.entries.append(store.gpa, .{ .path = path, .is_dir = is_dir });
    }

    pub fn count(store: Store) usize {
        return store.entries.items.len;
    }

    fn find(store: *Store, path: []const u8) ?usize {
        for (store.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
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

    /// The one entry point both doors reach. `args` is a path, or "from>to" for a move.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "file.list")) {
            // List the entries directly under the given directory prefix.
            if (input.args.len != 0 and !withinGrant(input.args)) return .failed;
            var under: usize = 0;
            for (store.entries.items) |entry| {
                if (input.args.len == 0 or std.mem.startsWith(u8, entry.path, input.args)) under += 1;
            }
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{under}) catch return .failed;
            return .{ .ok = text };
        }
        if (std.mem.eql(u8, op, "file.open")) {
            if (!withinGrant(input.args)) return .failed;
            return if (store.find(input.args) != null) .{ .ok = "opened" } else .failed;
        }

        // Mutations: confined to the grant and exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };

        if (std.mem.eql(u8, op, "file.edit")) {
            if (!withinGrant(input.args) or store.find(input.args) == null) return .failed;
            return store.commit(key, "edited");
        }
        if (std.mem.eql(u8, op, "file.move")) {
            const sep = std.mem.indexOfScalar(u8, input.args, '>') orelse return .failed;
            const from = input.args[0..sep];
            const to = input.args[sep + 1 ..];
            if (!withinGrant(from) or !withinGrant(to)) return .failed;
            const index = store.find(from) orelse return .failed;
            store.entries.items[index].path = to;
            return store.commit(key, "moved");
        }
        if (std.mem.eql(u8, op, "file.share")) {
            if (!withinGrant(input.args) or store.find(input.args) == null) return .failed;
            return store.commit(key, "shared");
        }
        if (std.mem.eql(u8, op, "file.delete")) {
            const index = store.find(input.args) orelse return .failed;
            _ = store.entries.orderedRemove(index);
            return store.commit(key, "deleted");
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

test "a path that escapes the granted folder is outside the grant" {
    try testing.expect(withinGrant("documents/notes.txt"));
    try testing.expect(!withinGrant("../other/secrets"));
    try testing.expect(!withinGrant("/etc/passwd"));
}

test "editing, moving, and deleting change the real tree, exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.add("documents/report.txt", false);
    try store.add("documents/old.txt", false);

    // Move report.txt to archive/report.txt.
    _ = Store.execute(&store, .{ .operation = "file.move", .args = "documents/report.txt>archive/report.txt" }, agent(), 1);
    try testing.expect(store.find("archive/report.txt") != null);
    try testing.expect(store.find("documents/report.txt") == null);

    // Delete old.txt, exactly once.
    _ = Store.execute(&store, .{ .operation = "file.delete", .args = "documents/old.txt" }, agent(), 2);
    _ = Store.execute(&store, .{ .operation = "file.delete", .args = "documents/old.txt" }, agent(), 2);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "an operation on a path outside the grant is refused before it touches the tree" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.add("documents/report.txt", false);
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "file.open", .args = "../escape" }, agent(), 1));
}
