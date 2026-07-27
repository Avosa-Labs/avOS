//! The card: the rounded, optionally raised surface that groups rows or content.
//!
//! The reference design sets everything on cards — a settings group, an agent's plan, a
//! conversation — so the card's shape is decided once here: its fill and corner radius from the
//! tokens, and, when it is raised above the background, the soft shadow the tokens define. A flat
//! card sits on the surface; a raised one lifts, for a sheet or a thing brought to attention. It
//! draws nothing; a surface fills the rounded rectangle and lays its content inside.

const std = @import("std");
const theme = @import("../theme/theme.zig");

pub const Colour = theme.Colour;

/// Whether a card sits flat on the surface or is lifted above it with a shadow.
pub const Elevation = enum { flat, raised };

/// A card: an elevation, from which its fill, radius, and shadow follow.
pub const Card = struct {
    elevation: Elevation = .flat,

    pub fn fill(card: Card) Colour {
        return switch (card.elevation) {
            .flat => theme.screen_card,
            .raised => theme.screen_card_tint,
        };
    }

    /// A card's corner radius — the large-radius role the design uses for surfaces.
    pub fn radius(_: Card) @TypeOf(theme.radius_lg) {
        return theme.radius_lg;
    }

    /// Whether the card casts the tokens' soft shadow — only a raised card lifts off the surface.
    pub fn hasShadow(card: Card) bool {
        return card.elevation == .raised;
    }

    pub fn shadowColour(_: Card) Colour {
        return theme.card_shadow;
    }
};

// --- Tests ---

const testing = std.testing;

test "a flat card fills with the card colour and casts no shadow" {
    const card = Card{};
    try testing.expect(std.meta.eql(card.fill(), theme.screen_card));
    try testing.expect(!card.hasShadow());
}

test "a raised card takes the tint fill and casts the shadow" {
    const card = Card{ .elevation = .raised };
    try testing.expect(std.meta.eql(card.fill(), theme.screen_card_tint));
    try testing.expect(card.hasShadow());
    try testing.expect(std.meta.eql(card.shadowColour(), theme.card_shadow));
}

test "a card uses the large-radius surface role" {
    try testing.expectEqual(theme.radius_lg, (Card{}).radius());
}
