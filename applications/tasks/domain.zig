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
// The platform slice (calendar dates) reached through the frame — an app file may not import the
// core plane directly, so the framework re-exports what due dates need.
const core = framework.platform;

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

const Task = struct { title: []const u8, done: bool = false, due: ?core.civil.Date = null };
const Applied = struct { key: u128, result: []const u8 };

/// Parses a "YYYY-MM-DD" date, the form a due date is given in. Null on any malformed field.
fn parseDate(text: []const u8) ?core.civil.Date {
    var it = std.mem.splitScalar(u8, text, '-');
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const d = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    if (m < 1 or m > 12 or d < 1 or d > core.civil.daysInMonth(y, m)) return null;
    return .{ .year = y, .month = m, .day = d };
}

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

    /// The due date set on a task, or null if the task has none (or does not exist).
    pub fn dueOf(store: *Store, title: []const u8) ?core.civil.Date {
        const idx = store.find(title) orelse return null;
        return store.tasks.items[idx].due;
    }

    /// How many open tasks are overdue as of a given day: not done, with a due date strictly before it.
    /// A task due on the day itself is not yet overdue.
    pub fn overdueCount(store: Store, as_of: core.civil.Date) usize {
        const today = core.civil.toDays(as_of);
        var n: usize = 0;
        for (store.tasks.items) |task| {
            if (task.done) continue;
            if (task.due) |due| {
                if (core.civil.toDays(due) < today) n += 1;
            }
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
        if (std.mem.eql(u8, op, "task.due")) {
            // Setting a due date is a local change. `args` is "title@YYYY-MM-DD".
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const idx = store.find(input.args[0..at]) orelse return .failed;
            const due = parseDate(input.args[at + 1 ..]) orelse return .failed;
            store.tasks.items[idx].due = due;
            return store.commit(key, "scheduled");
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

test "a due date makes a task overdue once the day has passed, and completing clears it" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "task.add", .args = "File taxes" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "task.add", .args = "Renew visa" }, agent(), 2);
    _ = Store.execute(&store, .{ .operation = "task.due", .args = "File taxes@2026-04-15" }, agent(), 3);
    _ = Store.execute(&store, .{ .operation = "task.due", .args = "Renew visa@2026-09-01" }, agent(), 4);
    try testing.expectEqual(core.civil.Date{ .year = 2026, .month = 4, .day = 15 }, store.dueOf("File taxes").?);

    // As of May 1st, taxes are overdue; the visa (September) is not.
    try testing.expectEqual(@as(usize, 1), store.overdueCount(.{ .year = 2026, .month = 5, .day = 1 }));
    // On the due day itself a task is not yet overdue.
    try testing.expectEqual(@as(usize, 0), store.overdueCount(.{ .year = 2026, .month = 4, .day = 15 }));
    // Completing the overdue task takes it out of the overdue count.
    _ = Store.execute(&store, .{ .operation = "task.complete", .args = "File taxes" }, agent(), 5);
    try testing.expectEqual(@as(usize, 0), store.overdueCount(.{ .year = 2026, .month = 5, .day = 1 }));

    // A malformed date is refused, leaving the task's due date unchanged.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "task.due", .args = "Renew visa@2026-13-40" }, agent(), 6));
    try testing.expectEqual(core.civil.Date{ .year = 2026, .month = 9, .day = 1 }, store.dueOf("Renew visa").?);
}
