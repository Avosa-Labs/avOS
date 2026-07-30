//! The Notes domain: a real local notebook a person and their agents write, read, and organise —
//! notes with a title and a body, created, edited, and deleted for real, no third party involved.
//!
//! This is the "one domain" both doors reach, holding actual notes. Listing and reading are silent
//! reads; creating and editing are ordinary local changes an agent may make and the person sees;
//! deleting a note is irreversible, so an agent's delete is held for the person. Every change is
//! exactly-once by key. A note is entirely local — it needs no account and no network — so the
//! notebook is real the moment it exists; a cloud sync, if a person ever wants one, is an additive
//! connector over this already-working store, not a precondition for it.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

const Note = struct { title: []const u8, body: []const u8, pinned: bool = false };
const Applied = struct { key: u128, result: []const u8 };

/// The part of an argument before the "|": a note's title. Arguments are "title" or "title|body".
fn titlePart(args: []const u8) []const u8 {
    const bar = std.mem.indexOfScalar(u8, args, '|') orelse return args;
    return args[0..bar];
}

/// The body part of an argument, after the "|", or empty if none.
fn bodyPart(args: []const u8) []const u8 {
    const bar = std.mem.indexOfScalar(u8, args, '|') orelse return "";
    return args[bar + 1 ..];
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    notes: std.ArrayListUnmanaged(Note) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.notes.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.notes.items.len;
    }

    fn find(store: *Store, title: []const u8) ?usize {
        for (store.notes.items, 0..) |note, i| {
            if (std.mem.eql(u8, note.title, title)) return i;
        }
        return null;
    }

    /// The body of a note by title, or null if there is no such note — how the surface reads a note.
    pub fn body(store: *Store, title: []const u8) ?[]const u8 {
        const idx = store.find(title) orelse return null;
        return store.notes.items[idx].body;
    }

    /// Whether a note is pinned, or null if there is no such note.
    pub fn isPinned(store: *Store, title: []const u8) ?bool {
        const idx = store.find(title) orelse return null;
        return store.notes.items[idx].pinned;
    }

    /// Searches the notebook for notes whose title or body contains `query`, case-insensitively.
    /// Matches are written into `out` as titles, in notebook order; an empty query matches every note.
    /// A search is a silent read — it names the notes that match, never quoting their bodies.
    pub fn search(store: Store, query: []const u8, out: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (store.notes.items) |note| {
            if (n >= out.len) break;
            const hit = query.len == 0 or
                std.ascii.indexOfIgnoreCase(note.title, query) != null or
                std.ascii.indexOfIgnoreCase(note.body, query) != null;
            if (hit) {
                out[n] = note.title;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// How many notes are pinned — the count the notebook surfaces at the top.
    pub fn pinnedCount(store: Store) usize {
        var n: usize = 0;
        for (store.notes.items) |note| {
            if (note.pinned) n += 1;
        }
        return n;
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

    /// The one entry point both doors reach. `args` is a note title, or "title|body".
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "note.list")) {
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{store.count()}) catch return .failed;
            return .{ .ok = text };
        }
        if (std.mem.eql(u8, op, "note.read")) {
            return if (store.find(input.args) != null) .{ .ok = "read" } else .failed;
        }
        if (std.mem.eql(u8, op, "note.search")) {
            // A silent read: the count of notes matching `args` across titles and bodies; the matched
            // titles are the surface's to read through `search`.
            var buffer: [64][]const u8 = undefined;
            const matches = store.search(input.args, &buffer);
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{matches.len}) catch return .failed;
            return .{ .ok = text };
        }
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "note.create")) {
            const title = titlePart(input.args);
            if (title.len == 0 or store.find(title) != null) return .failed;
            store.notes.append(store.gpa, .{ .title = title, .body = bodyPart(input.args) }) catch return .failed;
            return store.commit(key, "created");
        }
        if (std.mem.eql(u8, op, "note.edit")) {
            const title = titlePart(input.args);
            const idx = store.find(title) orelse return .failed;
            store.notes.items[idx].body = bodyPart(input.args);
            return store.commit(key, "edited");
        }
        if (std.mem.eql(u8, op, "note.pin")) {
            // Pinning keeps a note at the top — a local change; pinning an already-pinned note is a no-op.
            const idx = store.find(input.args) orelse return .failed;
            store.notes.items[idx].pinned = true;
            return store.commit(key, "pinned");
        }
        if (std.mem.eql(u8, op, "note.delete")) {
            // Deleting a note is irreversible — an agent's delete is held for the person.
            const idx = store.find(input.args) orelse return .failed;
            _ = store.notes.orderedRemove(idx);
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

test "creating, reading, editing, and deleting a note change the real notebook, once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "note.create", .args = "Trip|Lisbon in autumn" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "note.create", .args = "Trip|duplicate" }, agent(), 2); // same title refused
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expectEqualStrings("Lisbon in autumn", store.body("Trip").?);

    _ = Store.execute(&store, .{ .operation = "note.edit", .args = "Trip|Lisbon in October" }, agent(), 3);
    try testing.expectEqualStrings("Lisbon in October", store.body("Trip").?);

    try testing.expectEqualStrings("read", Store.execute(&store, .{ .operation = "note.read", .args = "Trip" }, agent(), 0).ok);
    try testing.expectEqualStrings("1", Store.execute(&store, .{ .operation = "note.list", .args = "" }, agent(), 0).ok);

    _ = Store.execute(&store, .{ .operation = "note.delete", .args = "Trip" }, agent(), 4);
    _ = Store.execute(&store, .{ .operation = "note.delete", .args = "Trip" }, agent(), 4); // same key, no double
    try testing.expectEqual(@as(usize, 0), store.count());
    // Reading or editing a missing note fails.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "note.read", .args = "Trip" }, agent(), 0));
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "note.edit", .args = "Trip|x" }, agent(), 5));
}

test "pinning keeps a note marked, and the pinned count reflects it" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "note.create", .args = "Groceries|milk, eggs" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "note.create", .args = "Ideas|a notebook OS" }, agent(), 2);
    try testing.expectEqual(@as(usize, 0), store.pinnedCount());
    try testing.expect(!store.isPinned("Ideas").?);

    _ = Store.execute(&store, .{ .operation = "note.pin", .args = "Ideas" }, agent(), 3);
    try testing.expect(store.isPinned("Ideas").?);
    try testing.expectEqual(@as(usize, 1), store.pinnedCount());
    // Pinning again under a new key is a harmless no-op — still one pinned note.
    _ = Store.execute(&store, .{ .operation = "note.pin", .args = "Ideas" }, agent(), 4);
    try testing.expectEqual(@as(usize, 1), store.pinnedCount());
    // Pinning a missing note fails.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "note.pin", .args = "Ghost" }, agent(), 5));
}

test "search matches across titles and bodies, case-insensitively, and counts through the door" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "note.create", .args = "Groceries|milk and eggs" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "note.create", .args = "Trip|book a flight to Lisbon" }, agent(), 2);
    _ = Store.execute(&store, .{ .operation = "note.create", .args = "Milk run|nothing here" }, agent(), 3);

    var buf: [8][]const u8 = undefined;
    // "milk" matches a body (Groceries) and a title (Milk run), case-insensitively — two notes.
    try testing.expectEqual(@as(usize, 2), store.search("MILK", &buf).len);
    // A body-only term matches its note.
    try testing.expectEqual(@as(usize, 1), store.search("lisbon", &buf).len);
    // An empty query matches every note; a miss matches none.
    try testing.expectEqual(@as(usize, 3), store.search("", &buf).len);
    try testing.expectEqual(@as(usize, 0), store.search("zzz", &buf).len);
    // The count comes back through the door as a silent read.
    try testing.expectEqualStrings("2", Store.execute(&store, .{ .operation = "note.search", .args = "milk" }, agent(), 0).ok);
}
