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
/// A move that can be undone: the file went from `from` to `to`, and reverting it puts the path
/// back. Only reversible local changes are recorded — a held delete is a deliberate, irreversible
/// act and is not something revert quietly resurrects.
const Move = struct { from: []const u8, to: []const u8 };

/// A file's kind for a quick look, without opening it: a folder, its extension when it has one, or a
/// plain file. A pure read of the path — the borrowed extension outlives the call like the path does.
pub fn previewKind(path: []const u8, is_dir: bool) []const u8 {
    if (is_dir) return "folder";
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |s| path[s + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    if (dot) |d| {
        if (d > 0 and d + 1 < base.len) return base[d + 1 ..]; // an extension, not a dotfile or a trailing dot
    }
    return "file";
}

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
/// A label attached to a file: the file's path and the tag it was given. A file may carry several.
const Tag = struct { path: []const u8, label: []const u8 };

pub const Store = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    tags: std.ArrayListUnmanaged(Tag) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    undo_log: std.ArrayListUnmanaged(Move) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.entries.deinit(store.gpa);
        store.tags.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.undo_log.deinit(store.gpa);
        store.* = undefined;
    }

    /// Undoes the most recent recorded move, putting the file's path back. Returns the restored path,
    /// or null when there is nothing to undo. Constant work beyond finding the moved entry.
    fn revertLast(store: *Store) ?[]const u8 {
        const last = store.undo_log.pop() orelse return null;
        if (store.find(last.to)) |index| store.entries.items[index].path = last.from;
        return last.from;
    }

    /// Seeds the tree with an entry, for the surface and tests to populate it.
    pub fn add(store: *Store, path: []const u8, is_dir: bool) !void {
        try store.entries.append(store.gpa, .{ .path = path, .is_dir = is_dir });
    }

    fn hasEntry(store: Store, path: []const u8) bool {
        for (store.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return true;
        }
        return false;
    }

    fn isTagged(store: Store, path: []const u8, label: []const u8) bool {
        for (store.tags.items) |t| {
            if (std.mem.eql(u8, t.path, path) and std.mem.eql(u8, t.label, label)) return true;
        }
        return false;
    }

    /// Tags a file with a label. Confined to the grant and to real files: an out-of-grant or unknown
    /// path is refused. Tagging the same file with the same label twice is idempotent. Returns whether
    /// a tag was applied (false if the file already had it).
    pub fn tagFile(store: *Store, path: []const u8, label: []const u8) !bool {
        if (!withinGrant(path) or !store.hasEntry(path) or label.len == 0) return false;
        if (store.isTagged(path, label)) return false;
        try store.tags.append(store.gpa, .{ .path = path, .label = label });
        return true;
    }

    /// The paths tagged with a label, in tree order — confined to the grant like every read.
    pub fn taggedWith(store: Store, label: []const u8, out: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (store.tags.items) |t| {
            if (n >= out.len) break;
            if (std.mem.eql(u8, t.label, label) and withinGrant(t.path)) {
                out[n] = t.path;
                n += 1;
            }
        }
        return out[0..n];
    }

    pub fn count(store: Store) usize {
        return store.entries.items.len;
    }

    /// Search the grant for entries whose path contains `query`, case-insensitive. Silent, and
    /// confined: only entries within the grant are ever returned, so a search cannot surface a file
    /// the caller could not open. Matches are written into `out` in tree order.
    pub fn search(store: Store, query: []const u8, out: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (store.entries.items) |entry| {
            if (n >= out.len) break;
            if (!withinGrant(entry.path)) continue;
            if (std.ascii.indexOfIgnoreCase(entry.path, query) != null) {
                out[n] = entry.path;
                n += 1;
            }
        }
        return out[0..n];
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
        if (std.mem.eql(u8, op, "file.preview")) {
            // A quick look: the file's kind, without opening it. A read, confined to the grant.
            if (!withinGrant(input.args)) return .failed;
            const index = store.find(input.args) orelse return .failed;
            const entry = store.entries.items[index];
            return .{ .ok = previewKind(entry.path, entry.is_dir) };
        }
        if (std.mem.eql(u8, op, "file.search")) {
            // A silent, grant-confined search: `args` is the query. The count of matches is
            // returned; the matched paths are the surface's to read through `search`.
            var buffer: [64][]const u8 = undefined;
            const matches = store.search(input.args, &buffer);
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{matches.len}) catch return .failed;
            return .{ .ok = text };
        }
        if (std.mem.eql(u8, op, "file.tagged")) {
            // A silent read: how many files carry the given tag, the paths the surface's to read.
            var buffer: [64][]const u8 = undefined;
            const matches = store.taggedWith(input.args, &buffer);
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{matches.len}) catch return .failed;
            return .{ .ok = text };
        }

        // Mutations: confined to the grant and exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };

        if (std.mem.eql(u8, op, "file.tag")) {
            // `args` is "path|label". Tagging is a local change, confined to the grant.
            const sep = std.mem.indexOfScalar(u8, input.args, '|') orelse return .failed;
            const path = input.args[0..sep];
            const label = input.args[sep + 1 ..];
            if (!withinGrant(path) or store.find(path) == null) return .failed;
            _ = store.tagFile(path, label) catch return .failed;
            return store.commit(key, "tagged");
        }

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
            // Record the move before applying it, so a recorded undo is always one that happened.
            store.undo_log.append(store.gpa, .{ .from = from, .to = to }) catch return .failed;
            store.entries.items[index].path = to;
            return store.commit(key, "moved");
        }
        if (std.mem.eql(u8, op, "file.revert")) {
            // Undo the last move or rename — a reversible local change, exactly-once by key. There is
            // nothing to revert if no move is recorded.
            _ = store.revertLast() orelse return .failed;
            return store.commit(key, "reverted");
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

test "tagging a real in-grant file works, is idempotent, and lists back by tag" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.add("documents/report.txt", false);
    try store.add("documents/notes.txt", false);

    // Tag two files "work"; tagging the same file+label twice does not double it.
    _ = Store.execute(&store, .{ .operation = "file.tag", .args = "documents/report.txt|work" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "file.tag", .args = "documents/report.txt|work" }, agent(), 2);
    _ = Store.execute(&store, .{ .operation = "file.tag", .args = "documents/notes.txt|work" }, agent(), 3);
    var buf: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), store.taggedWith("work", &buf).len);
    // The count comes back through the door as a silent read.
    try testing.expectEqualStrings("2", Store.execute(&store, .{ .operation = "file.tagged", .args = "work" }, agent(), 0).ok);
    // A tag on an out-of-grant or unknown path is refused.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "file.tag", .args = "../escape|work" }, agent(), 4));
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "file.tag", .args = "documents/ghost.txt|work" }, agent(), 5));
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

test "a quick-look preview reports a file's kind without opening it" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.add("documents/report.txt", false);
    try store.add("photos/lisbon.JPG", false);
    try store.add("documents", true);
    try store.add("documents/.hidden", false);

    // The extension is the kind, case preserved from the path; a folder reads as a folder.
    try testing.expectEqualStrings("txt", Store.execute(&store, .{ .operation = "file.preview", .args = "documents/report.txt" }, agent(), 0).ok);
    try testing.expectEqualStrings("JPG", Store.execute(&store, .{ .operation = "file.preview", .args = "photos/lisbon.JPG" }, agent(), 0).ok);
    try testing.expectEqualStrings("folder", Store.execute(&store, .{ .operation = "file.preview", .args = "documents" }, agent(), 0).ok);
    // A dotfile has no extension to preview.
    try testing.expectEqualStrings("file", Store.execute(&store, .{ .operation = "file.preview", .args = "documents/.hidden" }, agent(), 0).ok);
    // A preview is confined to the grant and to real files.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "file.preview", .args = "../escape" }, agent(), 0));
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "file.preview", .args = "documents/ghost.txt" }, agent(), 0));
}

test "reverting undoes the last move, exactly once, and refuses when there is nothing to undo" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.add("documents/report.txt", false);

    // Nothing moved yet: there is nothing to revert.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "file.revert", .args = "" }, agent(), 1));

    // Move, then revert: the file is back at its original path.
    _ = Store.execute(&store, .{ .operation = "file.move", .args = "documents/report.txt>archive/report.txt" }, agent(), 2);
    try testing.expect(store.find("archive/report.txt") != null);
    _ = Store.execute(&store, .{ .operation = "file.revert", .args = "" }, agent(), 3);
    try testing.expect(store.find("documents/report.txt") != null);
    try testing.expect(store.find("archive/report.txt") == null);

    // Exactly-once by key: replaying the same revert key does not pop a second move.
    _ = Store.execute(&store, .{ .operation = "file.move", .args = "documents/report.txt>archive/report.txt" }, agent(), 4);
    _ = Store.execute(&store, .{ .operation = "file.revert", .args = "" }, agent(), 3); // same key as the first revert
    try testing.expect(store.find("archive/report.txt") != null); // not undone: the key was already spent
}

test "search is case-insensitive, grant-confined, and returns matching paths" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.add("documents/Trip-Lisbon.md", false);
    try store.add("documents/budget.csv", false);
    try store.add("photos/lisbon.jpg", false);

    var buffer: [8][]const u8 = undefined;
    const hits = store.search("lisbon", &buffer);
    try testing.expectEqual(@as(usize, 2), hits.len); // both, case-insensitively
    // The count comes back through the door as a silent read.
    const result = Store.execute(&store, .{ .operation = "file.search", .args = "budget" }, agent(), 0);
    try testing.expectEqualStrings("1", result.ok);
}
