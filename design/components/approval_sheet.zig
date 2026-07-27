//! The approval sheet: what a person is shown when an agent's consequential action is held for
//! their decision, and the three things they can do about it.
//!
//! When an agent proposes something consequential — a payment, an external send, a VPN — the
//! framework holds it and the person decides. Every hold across the whole system presents the same
//! sheet, so the decision always looks and works the same way: it names the operation, the agent
//! that proposed it, and the concrete detail (what changes, to whom), and it offers exactly three
//! affordances — approve this once, keep holding, or cancel all the agent's pending work. Deciding
//! these once here, rather than per app, is what makes "you are always the one who approves" a
//! property a person can rely on. This module is the sheet's content and its actions; it draws
//! nothing and executes nothing — the surface renders it, and the framework carries out the choice.

const std = @import("std");
const theme = @import("../theme/theme.zig");

pub const Colour = theme.Colour;

/// The three affordances an approval sheet always offers.
pub const Action = enum {
    /// Apply this one held operation, now, and nothing more.
    approve_once,
    /// Leave it held; decide later. Nothing happens until then.
    hold,
    /// Cancel this operation and the requesting agent's other pending work.
    cancel_all,

    pub fn label(action: Action) []const u8 {
        return switch (action) {
            .approve_once => "Approve once",
            .hold => "Hold",
            .cancel_all => "Cancel all",
        };
    }

    /// Whether choosing this changes the world — approving carries the held action out, cancelling
    /// tears work down; holding changes nothing, so only it is free of consequence.
    pub fn isConsequential(action: Action) bool {
        return action != .hold;
    }

    /// The action's colour from the design tokens: approving is positive, holding is the awaiting
    /// amber, cancelling is the denial red.
    pub fn colour(action: Action) Colour {
        return switch (action) {
            .approve_once => theme.teal,
            .hold => theme.amber,
            .cancel_all => theme.denied,
        };
    }
};

/// The affordances in the order the sheet presents them: the affirmative first, then hold, then
/// the destructive cancel last.
pub const actions = [_]Action{ .approve_once, .hold, .cancel_all };

/// What the sheet presents about a held operation awaiting a person's decision.
pub const Sheet = struct {
    /// The operation being held, in the person's terms — e.g. "Pay hotel deposit".
    operation: []const u8,
    /// The agent that proposed it, so the person knows who is asking.
    requesting_agent: []const u8,
    /// The concrete detail of the change — target, amount, old→new — or null when there is none.
    detail: ?[]const u8 = null,

    /// The three affordances, in presentation order. Every sheet offers the same three.
    pub fn actionList(_: Sheet) []const Action {
        return &actions;
    }
};

// --- Tests ---

const testing = std.testing;

test "the sheet always offers exactly the three affordances, in order" {
    const sheet = Sheet{ .operation = "Pay hotel deposit", .requesting_agent = "Planner", .detail = "€120 to Hotel Lisboa" };
    const offered = sheet.actionList();
    try testing.expectEqual(@as(usize, 3), offered.len);
    try testing.expectEqual(Action.approve_once, offered[0]);
    try testing.expectEqual(Action.hold, offered[1]);
    try testing.expectEqual(Action.cancel_all, offered[2]);
}

test "only holding is free of consequence; approving and cancelling change the world" {
    try testing.expect(Action.approve_once.isConsequential());
    try testing.expect(Action.cancel_all.isConsequential());
    try testing.expect(!Action.hold.isConsequential());
}

test "each affordance carries its token colour and a non-empty label" {
    try testing.expect(std.meta.eql(Action.approve_once.colour(), theme.teal));
    try testing.expect(std.meta.eql(Action.hold.colour(), theme.amber));
    try testing.expect(std.meta.eql(Action.cancel_all.colour(), theme.denied));
    for (actions) |action| try testing.expect(action.label().len > 0);
}
