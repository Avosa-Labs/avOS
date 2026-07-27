//! The avatar with presence: a person's or an agent's mark, and a dot showing whether they are
//! present, away, or — in agent-violet — an agent at work.
//!
//! Every surface that shows who is involved shows it the same way: a round mark with the initials,
//! and a small presence dot at its corner. The dot's colour is decided once here so it means the
//! same everywhere — an agent at work is the same violet as the agent chip, the co-habitation
//! signature, so a person can see at a glance when it is an agent and not another person acting. It
//! draws nothing; a surface renders the mark and the dot from this.

const std = @import("std");
const theme = @import("../theme/theme.zig");
const status_chip = @import("status_chip.zig");

pub const Colour = theme.Colour;

/// Whether the one an avatar stands for is present, and if an agent, that it is at work.
pub const Presence = enum {
    /// Present and available.
    present,
    /// Away — reachable, not active.
    away,
    /// Offline — no presence dot is shown.
    offline,
    /// An agent at work — the co-habitation signature.
    agent,
};

/// An avatar: a short label (initials) shown in the mark, and a presence.
pub const Avatar = struct {
    label: []const u8,
    presence: Presence,

    /// Whether a presence dot is shown at all — everything but offline shows one.
    pub fn showsPresence(avatar: Avatar) bool {
        return avatar.presence != .offline;
    }

    /// The presence dot's colour, or null when none is shown. An agent at work is the one
    /// agent-violet — reusing the status chip's agent colour, so a violet dot and a violet chip mean
    /// the same thing.
    pub fn presenceColour(avatar: Avatar) ?Colour {
        return switch (avatar.presence) {
            .present => theme.teal,
            .away => theme.amber,
            .offline => null,
            .agent => (status_chip.Chip{ .status = .agent }).colour(),
        };
    }
};

// --- Tests ---

const testing = std.testing;

test "an agent avatar's dot is the one agent-violet, matching the agent chip" {
    const avatar = Avatar{ .label = "PL", .presence = .agent };
    try testing.expect(avatar.showsPresence());
    const dot = avatar.presenceColour() orelse return error.TestUnexpectedResult;
    try testing.expect(std.meta.eql(dot, (status_chip.Chip{ .status = .agent }).colour()));
    try testing.expect(std.meta.eql(dot, theme.agent));
}

test "present and away avatars carry their status colour; offline shows no dot" {
    try testing.expect(std.meta.eql((Avatar{ .label = "AN", .presence = .present }).presenceColour().?, theme.teal));
    try testing.expect(std.meta.eql((Avatar{ .label = "AN", .presence = .away }).presenceColour().?, theme.amber));
    const offline = Avatar{ .label = "AN", .presence = .offline };
    try testing.expect(!offline.showsPresence());
    try testing.expect(offline.presenceColour() == null);
}
