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

const Note = struct { title: []const u8, body: []const u8 };
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
