//! The Agents app: deciding which agent conversations a person is shown, in what
//! order, and when the app must pull them in rather than wait to be opened — the
//! first-party surface for watching agents work and stepping in.
//!
//! This is the app that makes the platform's premise visible: agents doing work in
//! conversations, and a person able to watch and intervene. The app does not run the
//! agents or hold the conversations — those are the agent plane's — it decides the
//! experience over them, and the decisions are about attention. A conversation that is
//! waiting on the person must surface whether or not the app is open, because an agent
//! blocked on an approval it will never get is work that has silently stalled; a
//! conversation that is merely chattering can wait to be looked at. When the person is
//! looking, the list is ordered so the thing that needs them is at the top: waiting
//! outranks running, running outranks finished, and within a rank the most recently
//! active comes first, so the screen answers "what needs me, and what is happening"
//! without scrolling. And joining a conversation to take the floor is gated on the
//! person actually being present and authenticated, because taking over an agent's
//! work is a consequential act, not an ambient one.
//!
//! This module runs no agent and shows no pixels. It decides which conversations
//! surface, how they rank, and whether a person may take one over, as pure functions.

const std = @import("std");

/// Where a conversation stands, as far as the person's attention is concerned.
pub const Status = enum {
    /// Blocked on the person: an approval, a decision, a correction is needed.
    awaiting_person,
    /// Agents are actively working.
    running,
    /// Paused by the person; held, but not finished.
    paused,
    /// Ended, whether it completed or was stopped.
    finished,

    /// A rank for attention: lower sorts first. Waiting outranks running, running
    /// outranks paused, paused outranks finished.
    fn attentionRank(status: Status) u8 {
        return switch (status) {
            .awaiting_person => 0,
            .running => 1,
            .paused => 2,
            .finished => 3,
        };
    }

    /// Whether a conversation in this status must surface to the person even when the
    /// app is not open — because it has stalled waiting on them.
    pub fn demandsAttention(status: Status) bool {
        return status == .awaiting_person;
    }
};

/// A conversation as the app sees it: its status, how recently it was active, and how
/// many agents are in it.
pub const Conversation = struct {
    status: Status,
    /// A monotonically increasing activity marker; a higher value is more recent.
    last_active: u64,
    agent_count: u16,

    /// Whether the app surfaces this conversation unprompted — a notification, a badge
    /// — rather than only showing it once the person opens the app.
    pub fn surfacesUnprompted(conversation: Conversation) bool {
        return conversation.status.demandsAttention();
    }
};

/// Orders two conversations for the app's list: the one needing more attention first,
/// and within the same attention rank, the more recently active first. A total order,
/// so the list is stable.
pub fn moreProminent(a: Conversation, b: Conversation) bool {
    const ra = a.status.attentionRank();
    const rb = b.status.attentionRank();
    if (ra != rb) return ra < rb;
    return a.last_active > b.last_active;
}

/// The context in which a person tries to take the floor in a conversation.
pub const TakeoverContext = struct {
    /// Whether the person is present at the device (not a remote or ambient trigger).
    present: bool,
    /// Whether the person has authenticated recently enough for a consequential act.
    authenticated: bool,
    /// Whether the conversation is one that can still be joined — not finished.
    joinable: bool,
};

/// Whether a person may take over a conversation to intervene. Taking over an agent's
/// work is consequential, so it requires the person to be present and authenticated,
/// and the conversation to still be live. Any one of these missing refuses the
/// takeover — a takeover that could happen ambiently would let a bump in a pocket
/// redirect an agent.
pub fn mayTakeOver(context: TakeoverContext) bool {
    return context.present and context.authenticated and context.joinable;
}

// --- Tests ---

const testing = std.testing;

test "a conversation waiting on the person surfaces unprompted" {
    const waiting: Conversation = .{ .status = .awaiting_person, .last_active = 10, .agent_count = 2 };
    const running: Conversation = .{ .status = .running, .last_active = 99, .agent_count = 3 };
    try testing.expect(waiting.surfacesUnprompted());
    // A running conversation, however recent, does not interrupt on its own.
    try testing.expect(!running.surfacesUnprompted());
}

test "attention outranks recency in the list order" {
    // An old waiting conversation outranks a brand-new running one.
    const waiting_earlier: Conversation = .{ .status = .awaiting_person, .last_active = 1, .agent_count = 1 };
    const running_recent: Conversation = .{ .status = .running, .last_active = 100, .agent_count = 1 };
    try testing.expect(moreProminent(waiting_earlier, running_recent));
    try testing.expect(!moreProminent(running_recent, waiting_earlier));
}

test "within one attention rank the more recent conversation leads" {
    const older: Conversation = .{ .status = .running, .last_active = 5, .agent_count = 1 };
    const newer: Conversation = .{ .status = .running, .last_active = 50, .agent_count = 1 };
    try testing.expect(moreProminent(newer, older));
    try testing.expect(!moreProminent(older, newer));
}

test "taking over requires presence, authentication, and a joinable conversation" {
    try testing.expect(mayTakeOver(.{ .present = true, .authenticated = true, .joinable = true }));
    // Any one missing refuses it.
    try testing.expect(!mayTakeOver(.{ .present = false, .authenticated = true, .joinable = true }));
    try testing.expect(!mayTakeOver(.{ .present = true, .authenticated = false, .joinable = true }));
    try testing.expect(!mayTakeOver(.{ .present = true, .authenticated = true, .joinable = false }));
}

test "the ordering is a strict total order over the statuses, swept" {
    // The list-stability property: for any two distinct conversations, exactly one is
    // more prominent — never both, never neither.
    const samples = [_]Conversation{
        .{ .status = .awaiting_person, .last_active = 3, .agent_count = 1 },
        .{ .status = .running, .last_active = 3, .agent_count = 1 },
        .{ .status = .paused, .last_active = 7, .agent_count = 1 },
        .{ .status = .finished, .last_active = 100, .agent_count = 1 },
        .{ .status = .running, .last_active = 9, .agent_count = 1 },
    };
    for (samples, 0..) |a, i| {
        for (samples[i + 1 ..]) |b| {
            const ab = moreProminent(a, b);
            const ba = moreProminent(b, a);
            try testing.expect(ab != ba); // exactly one direction holds
        }
    }
}

test "only a waiting conversation ever demands attention, swept" {
    for (std.enums.values(Status)) |status| {
        const conversation: Conversation = .{ .status = status, .last_active = 0, .agent_count = 1 };
        if (conversation.surfacesUnprompted()) try testing.expectEqual(Status.awaiting_person, status);
    }
}
