//! todo-app — one domain, two doors, watched through the ledger.
//!
//! The whole thesis of an agent-native app is here in the smallest honest form. A todo
//! list has one domain — the items and the operations on them — and two doors onto it:
//! the person adds and completes items through the app's surface, and an agent adds and
//! completes them through registered capabilities. Both doors call the identical domain
//! function, so an agent adding a task runs the same code the person's tap runs; there
//! is no separate agent path that could do something the person never exercises. Adding
//! is exactly-once by the operation's key, so a re-driven or double-tapped add lands one
//! item. And the activity feed is read from the audit ledger, so watching the agent work
//! is watching the same record that gated it — not a message the agent wrote about
//! itself.
//!
//! Everything here runs through the real frame: the same `App.invoke`, the same tool
//! registry, the same ledger a shipped app uses.

const std = @import("std");
const core = @import("core");
const applications = @import("applications");
const harness = @import("../harness.zig");

const framework = applications.framework;
const Actor = framework.Actor;
const Input = framework.Input;
const DomainResult = framework.DomainResult;

const Item = struct {
    text: []const u8,
    done: bool,
    added_by: u128,
};

const Applied = struct {
    key: u128,
    index: usize,
};

/// The todo list: the real state both doors share. It owns its items and the record of
/// which add-keys have already taken effect, so an add re-driven under the same key
/// returns the first outcome rather than duplicating the item.
pub const List = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Item) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .gpa = gpa };
    }

    pub fn deinit(list: *List) void {
        list.items.deinit(list.gpa);
        list.applied.deinit(list.gpa);
        list.* = undefined;
    }

    pub fn count(list: List) usize {
        return list.items.items.len;
    }

    pub fn completed(list: List) usize {
        var total: usize = 0;
        for (list.items.items) |item| {
            if (item.done) total += 1;
        }
        return total;
    }

    fn priorIndex(list: List, key: u128) ?usize {
        for (list.applied.items) |entry| {
            if (entry.key == key) return entry.index;
        }
        return null;
    }

    /// The one entry point both doors reach. The framework has already decided the
    /// caller may run this operation and will record it; the domain does the work.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        const list: *List = @ptrCast(@alignCast(context));

        if (std.mem.eql(u8, input.operation, "todo.add")) {
            // Exactly-once: an add re-driven under the same key is the same add. This
            // is what makes an agent's retried step, or a person's double tap, land one
            // item rather than two.
            if (list.priorIndex(key) != null) return .{ .ok = "added" };
            list.items.append(list.gpa, .{ .text = input.args, .done = false, .added_by = actor.principal.value }) catch return .failed;
            list.applied.append(list.gpa, .{ .key = key, .index = list.items.items.len - 1 }) catch {
                _ = list.items.pop();
                return .failed;
            };
            return .{ .ok = "added" };
        }
        if (std.mem.eql(u8, input.operation, "todo.complete")) {
            const index = std.fmt.parseInt(usize, input.args, 10) catch return .failed;
            if (index >= list.items.items.len) return .failed;
            list.items.items[index].done = true; // Idempotent: completing twice is completed.
            return .{ .ok = "completed" };
        }
        if (std.mem.eql(u8, input.operation, "todo.list")) {
            return .{ .ok = "listed" }; // A read: the count is inspected directly by callers.
        }
        return .failed;
    }

    pub fn domain(list: *List) framework.Domain {
        return .{ .context = list, .execute_fn = execute };
    }
};

/// The tools the app publishes. Adding and completing are local mutations — the agent's
/// to make within its grant, needing no approval, because they change nothing outside
/// the device. Listing is a read.
pub const tools = [_]framework.Tool{
    .{ .name = "todo.add", .required_capability = "todo.write", .effect = .local_mutation },
    .{ .name = "todo.complete", .required_capability = "todo.write", .effect = .local_mutation },
    .{ .name = "todo.list", .required_capability = "todo.read", .effect = .read_only },
};

pub fn open(list: *List, ledger: *framework.Ledger) framework.App {
    return .{
        .name = "todo-app",
        .domain = list.domain(),
        .tools = .{ .tools = &tools },
        .ledger = ledger,
    };
}

/// What running the example established, read from the state and the ledger.
pub const Result = struct {
    item_count: usize,
    completed_count: usize,
    human_and_agent_both_in_feed: bool,
};

/// Runs the list against a real world through both doors: the person adds an item, an
/// agent adds another through its capability, and the person completes one. The identical
/// domain runs for both, and the feed — read from the ledger — carries both actors.
pub fn run(world: *harness.World) !Result {
    var list = List.init(world.gpa);
    defer list.deinit();
    var app = open(&list, &world.ledger);

    const person: Actor = .{ .kind = .human, .principal = harness.World.principal(0x01) };
    const agent: Actor = .{ .kind = .agent, .principal = harness.World.principal(0x0A) };

    // The person adds a task through the human door.
    _ = try app.invoke(person, .{ .operation = "todo.add", .args = "buy milk" }, "todo.write", true, 0x11);
    // The agent adds a task through the agent door — the same domain function.
    _ = try app.invoke(agent, .{ .operation = "todo.add", .args = "call the dentist" }, "todo.write", true, 0x12);
    // A retried agent add under the same key lands nothing new.
    _ = try app.invoke(agent, .{ .operation = "todo.add", .args = "call the dentist" }, "todo.write", true, 0x12);
    // The person completes the first task.
    _ = try app.invoke(person, .{ .operation = "todo.complete", .args = "0" }, "todo.write", true, 0x13);

    const person_feed = try world.feed(person.principal);
    defer world.gpa.free(person_feed);
    const agent_feed = try world.feed(agent.principal);
    defer world.gpa.free(agent_feed);

    return .{
        .item_count = list.count(),
        .completed_count = list.completed(),
        .human_and_agent_both_in_feed = harness.feedHas(person_feed, "todo.add", .succeeded) and
            harness.feedHas(agent_feed, "todo.add", .succeeded),
    };
}

// --- Tests ---

const testing = std.testing;

test "both doors reach one domain and the retry lands one item" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x201);
    defer world.deinit();

    const result = try run(&world);

    // The person's item and the agent's item — the retry did not add a third.
    try testing.expectEqual(@as(usize, 2), result.item_count);
    try testing.expectEqual(@as(usize, 1), result.completed_count);
    // The feed carries both the person and the agent, read from the ledger.
    try testing.expect(result.human_and_agent_both_in_feed);
}

test "an add without the write capability is denied and recorded, not run" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x202);
    defer world.deinit();

    var list = List.init(gpa);
    defer list.deinit();
    var app = open(&list, &world.ledger);
    const agent: Actor = .{ .kind = .agent, .principal = harness.World.principal(0x0A) };

    // Presenting the read capability for a write operation: the registry refuses it.
    const outcome = try app.invoke(agent, .{ .operation = "todo.add", .args = "x" }, "todo.read", true, 1);
    try testing.expect(outcome == .denied);
    try testing.expectEqual(@as(usize, 0), list.count()); // Nothing was added.

    const denials = try world.denials();
    defer gpa.free(denials);
    try testing.expect(harness.feedHas(denials, "todo.add", .denied));
}

test "completing an item twice leaves it completed once" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x203);
    defer world.deinit();

    var list = List.init(gpa);
    defer list.deinit();
    var app = open(&list, &world.ledger);
    const person: Actor = .{ .kind = .human, .principal = harness.World.principal(0x01) };

    _ = try app.invoke(person, .{ .operation = "todo.add", .args = "task" }, "todo.write", true, 1);
    _ = try app.invoke(person, .{ .operation = "todo.complete", .args = "0" }, "todo.write", true, 2);
    _ = try app.invoke(person, .{ .operation = "todo.complete", .args = "0" }, "todo.write", true, 3);
    try testing.expectEqual(@as(usize, 1), list.completed());
}
