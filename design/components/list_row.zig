//! The list row: the element nearly every screen is built from — a leading status dot, a title and
//! an optional subtitle, and an optional trailing value or status pill.
//!
//! The reference design is, over and over, rows on a card: a coloured dot, a name, a line of
//! detail under it, and a value or a pill on the right. Deciding that anatomy once here — its text
//! colours from the tokens, its dot colour reusing the status chip's meaning, its trailing either a
//! plain value or a pill — is what keeps every list in every app looking like one system rather
//! than each screen inventing its own row. It draws nothing; a surface lays the row out from this.

const std = @import("std");
const theme = @import("../theme/theme.zig");
const status_chip = @import("status_chip.zig");

pub const Colour = theme.Colour;

/// What sits at the right of a row: nothing, a plain value (e.g. "70%", "On"), or a status pill.
pub const Trailing = union(enum) {
    none,
    value: []const u8,
    chip: status_chip.Chip,
};

/// One row: a title, an optional subtitle, an optional leading status dot, and a trailing.
pub const Row = struct {
    title: []const u8,
    subtitle: ?[]const u8 = null,
    /// An optional leading dot, coloured by a status — the reference design's coloured bullet.
    dot: ?status_chip.Status = null,
    trailing: Trailing = .none,

    /// The leading dot's colour, or null when the row has no dot. It reuses the status chip's
    /// mapping so a dot and a pill of the same status are the same colour.
    pub fn dotColour(row: Row) ?Colour {
        if (row.dot) |status| return (status_chip.Chip{ .status = status }).colour();
        return null;
    }

    pub fn titleColour(_: Row) Colour {
        return theme.screen_text;
    }

    pub fn subtitleColour(_: Row) Colour {
        return theme.screen_text_muted;
    }

    /// Whether the row shows an agent acting on it — a violet dot, or an agent/live pill trailing.
    /// This is how the agent-presence layer surfaces uniformly: any row an agent touches says so.
    pub fn hasAgentPresence(row: Row) bool {
        if (row.dot) |status| {
            if (status == .agent or status == .live) return true;
        }
        switch (row.trailing) {
            .chip => |chip| return chip.status == .agent or chip.status == .live,
            else => return false,
        }
    }
};

// --- Tests ---

const testing = std.testing;

test "a plain row has token text colours, no dot, and no agent presence" {
    const row = Row{ .title = "Wi-Fi", .subtitle = "Home network", .trailing = .{ .value = "On" } };
    try testing.expect(std.meta.eql(row.titleColour(), theme.screen_text));
    try testing.expect(std.meta.eql(row.subtitleColour(), theme.screen_text_muted));
    try testing.expect(row.dotColour() == null);
    try testing.expect(!row.hasAgentPresence());
}

test "the leading dot reuses the status chip's colour" {
    const row = Row{ .title = "Deposit", .dot = .denied };
    const dot = row.dotColour() orelse return error.TestUnexpectedResult;
    try testing.expect(std.meta.eql(dot, theme.denied));
}

test "a row an agent touches reports agent presence, by dot or by pill" {
    try testing.expect((Row{ .title = "Route", .dot = .agent }).hasAgentPresence());
    try testing.expect((Row{ .title = "Inbox", .trailing = .{ .chip = .{ .status = .live } } }).hasAgentPresence());
    try testing.expect(!(Row{ .title = "Battery", .trailing = .{ .chip = .{ .status = .running } } }).hasAgentPresence());
}
