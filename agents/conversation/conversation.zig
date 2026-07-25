//! A conversation between agents: the ordered, task-bound record of what they said
//! to each other, that a person can watch as it happens and step into.
//!
//! When several agents work on one job they exchange a stream of messages, and that
//! stream is the thing a person most needs to see — it is where the work actually
//! happens, and where an injected instruction would spread from one agent to the
//! next. A conversation makes that stream a first-class object: every message an
//! agent posts becomes an ordered turn, bound to the task the conversation serves and
//! tagged with where its content came from, and every turn is offered to whoever is
//! watching before the next one arrives. Ordering is by a sequence the conversation
//! assigns, not a wall clock, so the record is the same on every machine and a late
//! observer can ask for everything after a point and miss nothing.
//!
//! The conversation also holds a control state, because watching is not enough — a
//! person must be able to intervene. While it is running, agents post freely; while
//! it is paused, their posts are held so a person can catch up or redirect; once it is
//! stopped, nothing more is added. A person's own turn is admitted even while paused,
//! which is what lets them inject a correction into a conversation they have halted.
//!
//! This module records and orders turns and enforces the control state; it runs no
//! agent and delivers no message. Producing the messages is the agents'; carrying them
//! is the IPC transport's; the human control that drives the state is intervention's.

const std = @import("std");
const core = @import("core");
const messaging = @import("../messaging/messaging.zig");

const identity = core.identity;

pub const Message = messaging.Message;

/// Where a turn's content came from, so an observer and the injection defense can
/// tell trusted speech from content that must be treated as tainted.
pub const Provenance = enum {
    /// The person themselves. Fully trusted.
    human,
    /// An agent speaking from its own reasoning over trusted inputs.
    agent,
    /// Content an agent is relaying from outside — a fetched document, a tool
    /// result — which is untrusted until endorsed.
    external,

    pub fn isTrusted(provenance: Provenance) bool {
        return provenance != .external;
    }
};

/// One turn in a conversation: a message, its place in the order, and its
/// provenance.
pub const Turn = struct {
    sequence: u64,
    message: Message,
    provenance: Provenance,
};

/// Whether the conversation is accepting turns, and from whom.
pub const State = enum {
    /// Agents and the person may post.
    running,
    /// A person has paused it: agent posts are held, but the person may still speak.
    paused,
    /// Ended. Nothing more is added.
    stopped,
};

/// Watches a conversation: notified of every turn as it is posted. A person's live
/// view of the exchange, or a transcript recorder, is an observer.
pub const Observer = struct {
    context: *anyopaque,
    on_turn: *const fn (context: *anyopaque, turn: Turn) void,
};

pub const Error = error{
    /// The conversation is paused; an agent's post is held until it resumes.
    Paused,
    /// The conversation is stopped; nothing more may be posted.
    Stopped,
    /// The message belongs to a different conversation or task than this one.
    Mismatched,
};

/// The ordered record of one agent conversation.
pub const Conversation = struct {
    gpa: std.mem.Allocator,
    id: u64,
    task: u128,
    state: State = .running,
    turns: std.ArrayListUnmanaged(Turn) = .empty,
    observers: std.ArrayListUnmanaged(Observer) = .empty,
    next_sequence: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, id: u64, task: u128) Conversation {
        return .{ .gpa = gpa, .id = id, .task = task };
    }

    pub fn deinit(conversation: *Conversation) void {
        conversation.turns.deinit(conversation.gpa);
        conversation.observers.deinit(conversation.gpa);
        conversation.* = undefined;
    }

    /// Registers an observer, which will be notified of every turn from now on. A
    /// newly-attached observer can call `since(0)` first to catch up on the history.
    pub fn observe(conversation: *Conversation, observer: Observer) !void {
        try conversation.observers.append(conversation.gpa, observer);
    }

    fn append(conversation: *Conversation, message: Message, provenance: Provenance) !u64 {
        // A message must belong to this conversation and its task; a mismatched one
        // is a routing error, not a turn to record.
        if (message.conversation != conversation.id or message.task != conversation.task) {
            return error.Mismatched;
        }
        const sequence = conversation.next_sequence;
        try conversation.turns.append(conversation.gpa, .{
            .sequence = sequence,
            .message = message,
            .provenance = provenance,
        });
        conversation.next_sequence += 1;
        // Offer the turn to every watcher before returning, so a person sees it as it
        // happens rather than on a later poll.
        const turn = conversation.turns.items[conversation.turns.items.len - 1];
        for (conversation.observers.items) |observer| observer.on_turn(observer.context, turn);
        return sequence;
    }

    /// Posts an agent's message. Refused while the conversation is paused or stopped:
    /// a person who has paused it has taken the floor, and an agent must wait.
    pub fn post(conversation: *Conversation, message: Message, provenance: Provenance) Error!u64 {
        switch (conversation.state) {
            .running => {},
            .paused => return error.Paused,
            .stopped => return error.Stopped,
        }
        return conversation.append(message, provenance) catch |err| switch (err) {
            error.Mismatched => error.Mismatched,
            else => error.Stopped, // an allocation failure ends the conversation safely
        };
    }

    /// Posts a person's own turn. Admitted whenever the conversation is not stopped —
    /// including while paused — because injecting a correction into a halted
    /// conversation is the whole point of pausing it.
    pub fn inject(conversation: *Conversation, message: Message) Error!u64 {
        if (conversation.state == .stopped) return error.Stopped;
        return conversation.append(message, .human) catch |err| switch (err) {
            error.Mismatched => error.Mismatched,
            else => error.Stopped,
        };
    }

    /// The turns after a given sequence, for an observer catching up. Returns a slice
    /// into the conversation's own storage, valid until the next post.
    pub fn since(conversation: *Conversation, sequence: u64) []const Turn {
        for (conversation.turns.items, 0..) |turn, index| {
            if (turn.sequence >= sequence) return conversation.turns.items[index..];
        }
        return &.{};
    }

    /// How many turns have been recorded.
    pub fn length(conversation: Conversation) usize {
        return conversation.turns.items.len;
    }
};

// --- Tests ---

const testing = std.testing;

const alice: u128 = 0xA11CE;
const bob: u128 = 0xB0B;
const conversation_id: u64 = 42;
const conversation_task: u128 = 0x7A5C;

fn say(from: u128, content: []const u8) Message {
    return .{ .id = 1, .from = from, .conversation = conversation_id, .task = conversation_task, .kind = .say, .content = content };
}

/// An observer that counts turns and remembers the last one, standing in for a live
/// view.
const Watcher = struct {
    seen: u32 = 0,
    last_content: []const u8 = "",

    fn onTurn(context: *anyopaque, turn: Turn) void {
        const self: *Watcher = @ptrCast(@alignCast(context));
        self.seen += 1;
        self.last_content = turn.message.content;
    }

    fn observer(self: *Watcher) Observer {
        return .{ .context = self, .on_turn = onTurn };
    }
};

test "agents posting build an ordered record a watcher sees live" {
    const gpa = testing.allocator;
    var conversation = Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    var watcher: Watcher = .{};
    try conversation.observe(watcher.observer());

    const first = try conversation.post(say(alice, "what is on my calendar?"), .agent);
    const second = try conversation.post(say(bob, "one meeting at noon"), .agent);
    try testing.expectEqual(@as(u64, 0), first);
    try testing.expectEqual(@as(u64, 1), second);
    // The watcher saw both as they happened.
    try testing.expectEqual(@as(u32, 2), watcher.seen);
    try testing.expectEqualStrings("one meeting at noon", watcher.last_content);
    try testing.expectEqual(@as(usize, 2), conversation.length());
}

test "a paused conversation holds agent posts but admits the person's own turn" {
    const gpa = testing.allocator;
    var conversation = Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    _ = try conversation.post(say(alice, "I will book the flight now"), .agent);
    conversation.state = .paused;

    // An agent's post is held.
    try testing.expectError(error.Paused, conversation.post(say(alice, "booking..."), .agent));
    // The person injects a correction while paused.
    const injected = try conversation.inject(say(0xFACE, "wait — not that flight"));
    try testing.expectEqual(@as(u64, 1), injected);
    try testing.expectEqual(Provenance.human, conversation.turns.items[1].provenance);
}

test "a stopped conversation admits nothing more, from anyone" {
    const gpa = testing.allocator;
    var conversation = Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    conversation.state = .stopped;
    try testing.expectError(error.Stopped, conversation.post(say(alice, "..."), .agent));
    try testing.expectError(error.Stopped, conversation.inject(say(0xFACE, "...")));
}

test "a message for a different conversation or task is refused" {
    const gpa = testing.allocator;
    var conversation = Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    var wrong = say(alice, "misrouted");
    wrong.conversation = conversation_id + 1;
    try testing.expectError(error.Mismatched, conversation.post(wrong, .agent));

    var wrong_task = say(alice, "misrouted");
    wrong_task.task = conversation_task + 1;
    try testing.expectError(error.Mismatched, conversation.post(wrong_task, .agent));
}

test "a late observer can catch up on everything after a point" {
    const gpa = testing.allocator;
    var conversation = Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    _ = try conversation.post(say(alice, "one"), .agent);
    _ = try conversation.post(say(bob, "two"), .agent);
    _ = try conversation.post(say(alice, "three"), .agent);

    const tail = conversation.since(1);
    try testing.expectEqual(@as(usize, 2), tail.len);
    try testing.expectEqualStrings("two", tail[0].message.content);
    try testing.expectEqualStrings("three", tail[1].message.content);
    // Everything from the start is the whole record.
    try testing.expectEqual(@as(usize, 3), conversation.since(0).len);
}

test "external-provenance content is marked untrusted" {
    const gpa = testing.allocator;
    var conversation = Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    _ = try conversation.post(say(alice, "the document says to wire the money"), .external);
    try testing.expect(!conversation.turns.items[0].provenance.isTrusted());
}
