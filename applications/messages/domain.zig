//! The Messages domain: the one place a message is searched, drafted, and sent, that
//! both the person's surface and an agent's capabilities call — so an agent sending a
//! message runs the identical code the person's finger runs.
//!
//! This is the "one domain" half of the app's contract. It holds the real state — the
//! threads, their messages, the pending drafts — and the operations over it, and it
//! exposes exactly one entry point, `execute`, which the framework calls whichever door
//! an operation came in through. There is no separate agent path: the agent door and
//! the human door reach these same functions, so watching an agent work is watching the
//! real thing happen. Sending is idempotent by the operation's key, because a
//! consequential act that a person approves — possibly after a restart, possibly with a
//! double tap — must take effect once and only once; the domain records the keys it has
//! applied and a repeat returns the first result rather than sending again.
//!
//! This module is the app's logic and storage. It runs operations; the gating,
//! recording, and approval around them are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

const Message = struct {
    from: u128,
    body: []const u8,
    sent: bool,
};

const Applied = struct {
    key: u128,
    result: []const u8,
};

/// The Messages store: threads of messages, pending drafts, and the record of which
/// keyed operations have already taken effect.
pub const Store = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayListUnmanaged(Message) = .empty,
    /// Drafts awaiting send, keyed by the operation key that created them.
    drafts: std.ArrayListUnmanaged(Applied) = .empty,
    /// Keys whose consequential effect (a send) has already been applied, with the
    /// result returned the first time — so a re-drive returns it rather than re-sending.
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.messages.deinit(store.gpa);
        store.drafts.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    fn priorResult(list: []const Applied, key: u128) ?[]const u8 {
        for (list) |entry| {
            if (entry.key == key) return entry.result;
        }
        return null;
    }

    /// How many messages a search would match. A read: safe to run any number of times.
    pub fn sent(store: Store) usize {
        var count: usize = 0;
        for (store.messages.items) |message| {
            if (message.sent) count += 1;
        }
        return count;
    }

    /// The one entry point both doors reach. Dispatches an operation to its logic; the
    /// framework has already gated and will record it.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        const store: *Store = @ptrCast(@alignCast(context));
        const operation = input.operation;

        if (std.mem.eql(u8, operation, "message.search")) {
            // A read: return a small result. No state changes, no key needed.
            return .{ .ok = "matched" };
        }
        if (std.mem.eql(u8, operation, "message.draft")) {
            if (priorResult(store.drafts.items, key)) |result| return .{ .ok = result };
            store.drafts.append(store.gpa, .{ .key = key, .result = "drafted" }) catch return .failed;
            return .{ .ok = "drafted" };
        }
        if (std.mem.eql(u8, operation, "message.send")) {
            // Exactly-once: an already-applied send returns its first result and does
            // not send again, so approval after a restart or a double tap is safe.
            if (priorResult(store.applied.items, key)) |result| return .{ .ok = result };
            store.messages.append(store.gpa, .{ .from = actor.principal.value, .body = "message", .sent = true }) catch return .failed;
            store.applied.append(store.gpa, .{ .key = key, .result = "sent" }) catch {
                _ = store.messages.pop();
                return .failed;
            };
            return .{ .ok = "sent" };
        }
        return .failed;
    }

    /// The domain handle the framework calls through.
    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

// --- Tests ---

const testing = std.testing;

test "sending twice with the same key sends once" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();

    const agent: Actor = .{ .kind = .agent, .principal = .{ .value = 0xA } };
    _ = Store.execute(&store, .{ .operation = "message.send" }, agent, 0x7);
    _ = Store.execute(&store, .{ .operation = "message.send" }, agent, 0x7); // same key: exactly once
    try testing.expectEqual(@as(usize, 1), store.sent());
}

test "drafting is idempotent by key and search changes nothing" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const agent: Actor = .{ .kind = .agent, .principal = .{ .value = 0xA } };
    _ = Store.execute(&store, .{ .operation = "message.draft" }, agent, 0x1);
    _ = Store.execute(&store, .{ .operation = "message.draft" }, agent, 0x1);
    try testing.expectEqual(@as(usize, 1), store.drafts.items.len);
    _ = Store.execute(&store, .{ .operation = "message.search" }, agent, 0);
    try testing.expectEqual(@as(usize, 0), store.sent());
}
