//! The Tasks domain: a real local to-do list a person and their agents keep — tasks with a title and
//! a done state, added, completed, and cleared for real, no third party involved.
//!
//! This is the "one domain" both doors reach, holding actual tasks. Listing and counting what is left
//! are silent reads; adding a task and marking it done are ordinary local changes an agent may make
//! and the person sees; clearing a task removes it and, being irreversible, an agent's clear is held
//! for the person. Every change is exactly-once by key. The list is entirely local — no account, no
//! network — so it is real the moment it exists.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

const Task = struct { title: []const u8, done: bool = false };
const Applied = struct { key: u128, result: []const u8 };

pub const Store = struct {
    gpa: std.mem.Allocator,
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.tasks.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.tasks.items.len;
    }

    /// How many tasks are still open — the count minus those marked done.
    pub fn remaining(store: Store) usize {
        var n: usize = 0;
        for (store.tasks.items) |task| {
            if (!task.done) n += 1;
        }
        return n;
    }

    fn find(store: *Store, title: []const u8) ?usize {
        for (store.tasks.items, 0..) |task, i| {
            if (std.mem.eql(u8, task.title, title)) return i;
        }
        return null;
    }

    /// Whether a task is done, or null if there is no such task.
    pub fn isDone(store: *Store, title: []const u8) ?bool {
        const idx = store.find(title) orelse return null;
        return store.tasks.items[idx].done;
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

    /// The one entry point both doors reach. `args` is a task title.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "task.list")) {
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{store.remaining()}) catch return .failed;
            return .{ .ok = text };
        }
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "task.add")) {
            if (input.args.len == 0 or store.find(input.args) != null) return .failed;
            store.tasks.append(store.gpa, .{ .title = input.args }) catch return .failed;
            return store.commit(key, "added");
        }
        if (std.mem.eql(u8, op, "task.complete")) {
            const idx = store.find(input.args) orelse return .failed;
            store.tasks.items[idx].done = true;
            return store.commit(key, "completed");
        }
        if (std.mem.eql(u8, op, "task.clear")) {
            // Clearing a task removes it — irreversible, so an agent's clear is held for the person.
            const idx = store.find(input.args) orelse return .failed;
            _ = store.tasks.orderedRemove(idx);
            return store.commit(key, "cleared");
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

test "adding, completing, and clearing tasks change the real list, once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "task.add", .args = "Book hotel" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "task.add", .args = "Book hotel" }, agent(), 2); // same title refused
    _ = Store.execute(&store, .{ .operation = "task.add", .args = "Pack bags" }, agent(), 3);
    try testing.expectEqual(@as(usize, 2), store.count());
    try testing.expectEqual(@as(usize, 2), store.remaining());

    // Completing one leaves it in the list but reduces what is remaining.
    _ = Store.execute(&store, .{ .operation = "task.complete", .args = "Book hotel" }, agent(), 4);
    try testing.expect(store.isDone("Book hotel").?);
    try testing.expectEqual(@as(usize, 1), store.remaining());
    try testing.expectEqualStrings("1", Store.execute(&store, .{ .operation = "task.list", .args = "" }, agent(), 0).ok);

    // Clearing removes it, exactly once by key.
    _ = Store.execute(&store, .{ .operation = "task.clear", .args = "Book hotel" }, agent(), 5);
    _ = Store.execute(&store, .{ .operation = "task.clear", .args = "Book hotel" }, agent(), 5);
    try testing.expectEqual(@as(usize, 1), store.count());
    // Completing or clearing a missing task fails.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "task.complete", .args = "Ghost" }, agent(), 6));
}
