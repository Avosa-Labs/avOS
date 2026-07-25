//! The Phone domain: a real call log a person and their agents read, screen, and add to
//! by placing calls — with an unknown, unverified caller screened before it rings.
//!
//! This is the "one domain" both doors reach. It holds the real call history and the
//! rule that decides whether an incoming call rings through or is screened. Reading the
//! history and running a screening check are reads; placing a call reaches another person
//! and is held for an agent, and it appends to the real log exactly-once by key.
//!
//! This module is the app's real logic and storage; the gating and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

pub const Caller = struct { known: bool, verified: bool };

/// Whether an incoming call rings the person directly, or is screened first.
pub fn ringsThrough(caller: Caller) bool {
    return caller.known or caller.verified;
}

const Call = struct { number: []const u8, outgoing: bool };
const Applied = struct { key: u128, result: []const u8 };

pub const Store = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayListUnmanaged(Call) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }
    pub fn deinit(store: *Store) void {
        store.log.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }
    pub fn calls(store: Store) usize {
        return store.log.items.len;
    }
    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |e| if (e.key == key) return e.result;
        return null;
    }
    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }
    /// The one entry point both doors reach. `args` is a phone number.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;
        if (std.mem.eql(u8, op, "call.history")) {
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{store.calls()}) catch return .failed;
            return .{ .ok = text };
        }
        if (std.mem.eql(u8, op, "call.screen")) return .{ .ok = "screened" };
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "call.dial")) {
            if (input.args.len == 0) return .failed;
            store.log.append(store.gpa, .{ .number = input.args, .outgoing = true }) catch return .failed;
            return store.commit(key, "dialled");
        }
        return .failed;
    }
    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

const testing = std.testing;
fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}
test "an unknown, unverified caller is screened rather than ringing through" {
    try testing.expect(ringsThrough(.{ .known = true, .verified = false }));
    try testing.expect(!ringsThrough(.{ .known = false, .verified = false }));
}
test "dialling appends to the real log exactly-once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "call.dial", .args = "5551234" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "call.dial", .args = "5551234" }, agent(), 1);
    try testing.expectEqual(@as(usize, 1), store.calls());
}
