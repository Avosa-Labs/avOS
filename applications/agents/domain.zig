//! The Agents domain: the roster of agent principals a person governs — who they are, the kind of
//! mind they run, what they are doing, and whether they still hold authority — and the two acts a
//! person makes over them: observing, and stepping in.
//!
//! This is the "one domain" both doors reach. It holds the real roster and the record of applied
//! keyed changes. Observing lists the roster and is silent; intervening in an agent's work is
//! consequential and, for an agent asking, held for the person. The kill switch — ending an agent's
//! authority at once — is the person's alone: it is structurally ungrantable, named by no agent
//! capability, so unlike a held operation an agent may request, no capability an agent holds can ever
//! reach it. An agent's kind is neutral to which vendor built it: a cloud model, a local model, and a
//! device agent are the same kind of participant, governed the same way.
//!
//! This module is the app's real logic and storage; the gating and recording are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const console = @import("console.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// The kind of mind an agent runs. A system statement, not a vendor slot: a cloud model, a local
/// model, and an embodied device agent are the same kind of governed participant.
pub const Kind = enum { cloud_model, local_model, device };

/// Where an agent stands for the person's attention — reused from the attention model so the roster
/// and the conversation list rank the same way.
pub const Status = console.Status;

/// One agent on the roster.
pub const Agent = struct {
    name: []const u8,
    kind: Kind,
    status: Status,
    /// Whether the agent still holds authority. The kill switch clears this at once.
    live: bool = true,
};

const Applied = struct { key: u128, result: []const u8 };

pub const Store = struct {
    gpa: std.mem.Allocator,
    roster: std.ArrayListUnmanaged(Agent) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.roster.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    /// Enrols an agent on the roster — how the surface populates it from the principal service.
    pub fn enroll(store: *Store, name: []const u8, kind: Kind, status: Status) !void {
        try store.roster.append(store.gpa, .{ .name = name, .kind = kind, .status = status });
    }

    pub fn count(store: Store) usize {
        return store.roster.items.len;
    }

    /// How many agents still hold authority — the roster minus those the kill switch has ended.
    pub fn liveCount(store: Store) usize {
        var n: usize = 0;
        for (store.roster.items) |entry| {
            if (entry.live) n += 1;
        }
        return n;
    }

    fn find(store: *Store, name: []const u8) ?usize {
        for (store.roster.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, name)) return index;
        }
        return null;
    }

    /// The kill switch: ends an agent's authority at once. This is the person's alone — it is not
    /// reachable through the agent door, so no capability an agent holds can ever invoke it.
    pub fn kill(store: *Store, name: []const u8) bool {
        const index = store.find(name) orelse return false;
        store.roster.items[index].live = false;
        return true;
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

    /// The one entry point both doors reach. `args` is an agent name for an intervention.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "agents.observe")) {
            // Silent: how many agents still hold authority.
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{store.liveCount()}) catch return .failed;
            return .{ .ok = text };
        }
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "agents.intervene")) {
            // Stepping into an agent's work: it must name a live agent on the roster.
            const index = store.find(input.args) orelse return .failed;
            if (!store.roster.items[index].live) return .failed;
            return store.commit(key, "intervened");
        }
        if (std.mem.eql(u8, op, "agents.request_task")) {
            // One agent proposing work to another: held for the person, exactly-once, and
            // only ever addressed to a live agent on the roster.
            const index = store.find(input.args) orelse return .failed;
            if (!store.roster.items[index].live) return .failed;
            return store.commit(key, "requested");
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

test "the roster holds agents of every kind, governed the same way" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.enroll("Planner", .cloud_model, .running);
    try store.enroll("Transcriber", .local_model, .running);
    try store.enroll("Rover", .device, .awaiting_person);
    try testing.expectEqual(@as(usize, 3), store.count());
    try testing.expectEqual(@as(usize, 3), store.liveCount());
}

test "the kill switch ends an agent's authority and is not an agent-reachable tool" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.enroll("Planner", .cloud_model, .running);
    try testing.expect(store.kill("Planner")); // the person ends it
    try testing.expectEqual(@as(usize, 0), store.liveCount());
    // An intervention now finds no live agent to step into.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "agents.intervene", .args = "Planner" }, agent(), 1));
}

test "observing is silent; intervening is exactly-once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.enroll("Planner", .cloud_model, .running);
    const observed = Store.execute(&store, .{ .operation = "agents.observe", .args = "" }, agent(), 0);
    try testing.expectEqualStrings("1", observed.ok);
    _ = Store.execute(&store, .{ .operation = "agents.intervene", .args = "Planner" }, agent(), 5);
    const again = Store.execute(&store, .{ .operation = "agents.intervene", .args = "Planner" }, agent(), 5);
    try testing.expectEqualStrings("intervened", again.ok); // same key, same one result
}

test "requesting a task addresses only a live agent, exactly-once" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.enroll("Planner", .cloud_model, .running);
    const requested = Store.execute(&store, .{ .operation = "agents.request_task", .args = "Planner" }, agent(), 3);
    try testing.expectEqualStrings("requested", requested.ok);
    // Exactly-once by key.
    const again = Store.execute(&store, .{ .operation = "agents.request_task", .args = "Planner" }, agent(), 3);
    try testing.expectEqualStrings("requested", again.ok);
    // No such agent, or one that is not live, cannot be tasked.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "agents.request_task", .args = "Ghost" }, agent(), 4));
}
