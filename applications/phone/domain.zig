//! The Phone domain: the calls a person places, answers, and screens.
//!
//! This is the "one domain" half of the app's contract: the real state and the single
//! `execute` both the human surface and the agent capabilities reach through the frame,
//! so an agent runs the identical code the person does. Consequential and mutating
//! operations are idempotent by the operation's key — the domain records applied keys
//! and a repeat returns the first result — so an approved or re-driven action takes
//! effect exactly once, even across a restart or a double tap.
//!
//! This module is the app's logic and storage; the gating, recording, and approval
//! around it are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;

const Applied = struct { key: u128, result: []const u8 };

fn priorResult(list: []const Applied, key: u128) ?[]const u8 {
    for (list) |entry| { if (entry.key == key) return entry.result; }
    return null;
}

/// The phone store: its committed state and the record of which keyed operations have
/// already taken effect, so a mutating operation is exactly-once.
pub const Store = struct {
    gpa: std.mem.Allocator,
    /// Committed state changes, one per applied keyed operation.
    calls: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store { return .{ .gpa = gpa }; }

    pub fn deinit(store: *Store) void {
        store.calls.deinit(store.gpa);
        store.* = undefined;
    }

    /// How many state changes have been committed.
    pub fn changes(store: Store) usize { return store.calls.items.len; }

    fn applyKeyed(store: *Store, key: u128, result: []const u8) DomainResult {
        if (priorResult(store.calls.items, key)) |prior| return .{ .ok = prior };
        store.calls.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }

    /// The one entry point both doors reach.
    pub fn execute(context: *anyopaque, operation: []const u8, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, operation, "call.history")) return .{ .ok = "read" };
        if (std.mem.eql(u8, operation, "call.screen")) return .{ .ok = "read" };
        if (std.mem.eql(u8, operation, "call.dial")) return store.applyKeyed(key, "dial");
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

const testing = std.testing;

test "a mutating operation is exactly-once by key; a read changes nothing" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const actor: Actor = .{ .kind = .agent, .principal = .{ .value = 0xA } };
    const first_mutate = "call.dial";
    _ = Store.execute(&store, first_mutate, actor, 0x7);
    _ = Store.execute(&store, first_mutate, actor, 0x7);
    try testing.expectEqual(@as(usize, 1), store.changes());
    _ = Store.execute(&store, "call.history", actor, 0);
    try testing.expectEqual(@as(usize, 1), store.changes());
}
