//! Deciding which agent activity items surface to the person and in what order, so a human
//! watching agents work sees what needs them before the routine hum of everything else.
//!
//! The activity feed is where a person watches agents act on their behalf, and the feed is
//! only trustworthy if nothing that needs a decision can hide beneath the chatter. An agent
//! produces a steady stream — messages, proposals, actions taken, completions, failures — and
//! most of it is background the person can glance past or let collapse. But an item that is
//! awaiting a human is a held breath: the agent has stopped and cannot proceed until the person
//! answers. Such items always surface, and they always rank above items that are not waiting,
//! so attention lands where work is blocked; among equals, the most recent comes first.
//!
//! This module surfaces nothing. It decides which activity items reach the person and how they
//! are ordered, as a pure function over each item's kind, whether it awaits a human, and its
//! place in the sequence.

const std = @import("std");

/// One entry in the agent activity feed.
pub const Item = struct {
    /// What the agent did or needs, which decides whether the entry is routine or must surface.
    kind: enum { message, action_proposed, action_taken, approval_needed, completed, failed },
    /// Whether the agent has stopped and needs a person to answer before it can continue.
    awaiting_human: bool,
    /// Monotonic position in the feed; a higher value is more recent.
    at_sequence: u64,
};

/// Whether an item is shown to the person rather than collapsed into the background.
///
/// Anything awaiting a human always surfaces — the agent is blocked and only the person can
/// unblock it. Routine chatter, a plain message that needs no decision, may be collapsed so it
/// does not bury the items that do; every other kind carries a consequence worth showing.
pub fn surfaced(item: Item) bool {
    if (item.awaiting_human) return true;
    return item.kind != .message;
}

/// Whether `a` should rank above `b` in the feed.
///
/// Items awaiting a human rank above those that are not, because blocked work is where the
/// person's attention is worth most. Among items on the same side of that line, the more recent
/// (higher sequence) comes first, so the freshest state leads.
pub fn moreUrgent(a: Item, b: Item) bool {
    if (a.awaiting_human != b.awaiting_human) return a.awaiting_human;
    return a.at_sequence > b.at_sequence;
}

test "everything awaiting a human is surfaced" {
    try std.testing.expect(surfaced(.{ .kind = .message, .awaiting_human = true, .at_sequence = 1 }));
}

test "routine chatter can be collapsed but consequential kinds surface" {
    try std.testing.expect(!surfaced(.{ .kind = .message, .awaiting_human = false, .at_sequence = 1 }));
    try std.testing.expect(surfaced(.{ .kind = .failed, .awaiting_human = false, .at_sequence = 1 }));
}

test "awaiting a human ranks above not, then recency breaks ties" {
    const waiting = Item{ .kind = .approval_needed, .awaiting_human = true, .at_sequence = 1 };
    const chatter = Item{ .kind = .message, .awaiting_human = false, .at_sequence = 9 };
    try std.testing.expect(moreUrgent(waiting, chatter));
    const older = Item{ .kind = .completed, .awaiting_human = false, .at_sequence = 2 };
    const newer = Item{ .kind = .completed, .awaiting_human = false, .at_sequence = 5 };
    try std.testing.expect(moreUrgent(newer, older));
}

test "no item awaiting a human is ever ranked below one that is not, swept" {
    // The attention property: a blocked item can never sit beneath an unblocked one, whatever
    // their sequence numbers.
    const seqs = [_]u64{ 0, 1, 7, 100 };
    for (seqs) |sa| for (seqs) |sb| {
        const waiting = Item{ .kind = .approval_needed, .awaiting_human = true, .at_sequence = sa };
        const not = Item{ .kind = .action_taken, .awaiting_human = false, .at_sequence = sb };
        try std.testing.expect(moreUrgent(waiting, not));
        try std.testing.expect(!moreUrgent(not, waiting));
    };
}
