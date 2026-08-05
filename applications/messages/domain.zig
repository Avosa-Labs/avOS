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

/// Who a party to a message is — the person, or an agent. An agent-to-agent exchange is one where
/// both ends are agents; the app renders it as a visible thread with both principals' chips, so
/// co-habitation is watchable rather than hidden.
pub const Party = enum { human, agent };

const Message = struct {
    from: u128,
    body: []const u8,
    sent: bool,
    /// Who the message is from and to. An agent-to-agent message has both as `agent`.
    from_party: Party = .human,
    to_party: Party = .human,
};

const Applied = struct {
    key: u128,
    result: []const u8,
};

/// A reply drafted but not yet sent: the body the draft carries, keyed by the operation
/// that created it. Held so the surface reads back the real drafted content — what a held
/// send shows the person — rather than repeating what it passed in.
const Draft = struct {
    key: u128,
    body: []const u8,
};

/// The Messages store: threads of messages, pending drafts, and the record of which
/// keyed operations have already taken effect.
pub const Store = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayListUnmanaged(Message) = .empty,
    /// Drafts awaiting send, keyed by the operation key that created them.
    drafts: std.ArrayListUnmanaged(Draft) = .empty,
    /// Keys whose consequential effect (a send) has already been applied, with the
    /// result returned the first time — so a re-drive returns it rather than re-sending.
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

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

    /// The total number of messages in the thread — everything sent or exchanged.
    pub fn messageCount(store: Store) usize {
        return store.messages.items.len;
    }

    /// The body of the i-th message in the thread, or null if there are fewer than i+1.
    pub fn bodyAt(store: Store, i: usize) ?[]const u8 {
        if (i >= store.messages.items.len) return null;
        return store.messages.items[i].body;
    }

    /// The body of the most recently drafted reply, or null if nothing is drafted — what the surface
    /// reads back so a held send shows the real drafted content, not a line it kept on the side.
    pub fn draftedBody(store: Store) ?[]const u8 {
        if (store.drafts.items.len == 0) return null;
        return store.drafts.items[store.drafts.items.len - 1].body;
    }

    /// Records an exchange between two identified parties into the thread — how the surface adds an
    /// agent-to-agent negotiation it derives from the ledger, both principals shown. The domain
    /// stores the exchange; it never invents one, so the thread is always ground truth.
    pub fn recordExchange(store: *Store, from_party: Party, to_party: Party) !void {
        try store.messages.append(store.gpa, .{ .from = 0, .body = "exchange", .sent = true, .from_party = from_party, .to_party = to_party });
    }

    /// How many messages in the thread are agent-to-agent — both ends an agent. These are the
    /// exchanges the app renders with both agents' chips.
    pub fn agentToAgentCount(store: Store) usize {
        var count: usize = 0;
        for (store.messages.items) |message| {
            if (message.from_party == .agent and message.to_party == .agent) count += 1;
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
        if (std.mem.eql(u8, operation, "message.read")) {
            // A read of the thread: how many messages it holds. Silent, repeatable.
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{store.messageCount()}) catch return .failed;
            return .{ .ok = text };
        }
        if (std.mem.eql(u8, operation, "message.draft")) {
            // Idempotent by key: a re-driven draft leaves the one already recorded. The body is kept so
            // the surface can read the real drafted content back for the held send.
            for (store.drafts.items) |existing| {
                if (existing.key == key) return .{ .ok = "drafted" };
            }
            const body = if (input.args.len > 0) input.args else "message";
            store.drafts.append(store.gpa, .{ .key = key, .body = body }) catch return .failed;
            return .{ .ok = "drafted" };
        }
        if (std.mem.eql(u8, operation, "message.send")) {
            // Exactly-once: an already-applied send returns its first result and does
            // not send again, so approval after a restart or a double tap is safe.
            if (priorResult(store.applied.items, key)) |result| return .{ .ok = result };
            const from_party: Party = if (actor.kind == .agent) .agent else .human;
            const message_body = if (input.args.len > 0) input.args else "message";
            store.messages.append(store.gpa, .{ .from = actor.principal.value, .body = message_body, .sent = true, .from_party = from_party }) catch return .failed;
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

test "a sent message keeps its real body, and the thread reads it back" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const agent: Actor = .{ .kind = .agent, .principal = .{ .value = 0xA } };
    _ = Store.execute(&store, .{ .operation = "message.send", .args = "On my way" }, agent, 0x1);
    _ = Store.execute(&store, .{ .operation = "message.send", .args = "Running late" }, agent, 0x2);
    try testing.expectEqual(@as(usize, 2), store.messageCount());
    try testing.expectEqualStrings("On my way", store.bodyAt(0).?);
    try testing.expectEqualStrings("Running late", store.bodyAt(1).?);
    // Reading the thread returns its length as a silent read.
    try testing.expectEqualStrings("2", Store.execute(&store, .{ .operation = "message.read" }, agent, 0).ok);
    try testing.expect(store.bodyAt(2) == null);
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

test "a draft keeps its body, read back for the held send it precedes" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const agent: Actor = .{ .kind = .agent, .principal = .{ .value = 0xA } };
    try testing.expect(store.draftedBody() == null);
    _ = Store.execute(&store, .{ .operation = "message.draft", .args = "On my way" }, agent, 0x1);
    try testing.expectEqualStrings("On my way", store.draftedBody().?);
    // Re-driving the same key does not add a second draft or lose the body.
    _ = Store.execute(&store, .{ .operation = "message.draft", .args = "On my way" }, agent, 0x1);
    try testing.expectEqual(@as(usize, 1), store.drafts.items.len);
    try testing.expectEqualStrings("On my way", store.draftedBody().?);
}

test "an agent-to-agent exchange is a visible thread with both parties identified" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // A person messaging an agent, and two agents negotiating with each other.
    try store.recordExchange(.human, .agent);
    try store.recordExchange(.agent, .agent);
    try store.recordExchange(.agent, .agent);
    // Only the two agent-to-agent exchanges are rendered with both agents' chips.
    try testing.expectEqual(@as(usize, 2), store.agentToAgentCount());
}

test "an agent's send is recorded as from an agent, a person's as from the person" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const agent: Actor = .{ .kind = .agent, .principal = .{ .value = 0xA } };
    const human: Actor = .{ .kind = .human, .principal = .{ .value = 0x1 } };
    _ = Store.execute(&store, .{ .operation = "message.send" }, agent, 1);
    _ = Store.execute(&store, .{ .operation = "message.send" }, human, 2);
    try testing.expectEqual(Party.agent, store.messages.items[0].from_party);
    try testing.expectEqual(Party.human, store.messages.items[1].from_party);
}
