//! The search field: a query input with a placeholder, and the filter rule a list uses to narrow
//! itself as the person types.
//!
//! Search is the same everywhere in the design — a field with muted placeholder text until the
//! person types, then the query in full-strength text — so its look and its behaviour are decided
//! once here. The behaviour is the part worth sharing: an empty query matches everything (the list
//! is unfiltered), and a non-empty one matches a candidate case-insensitively by substring, so a
//! settings search, a contacts search, and a store search all narrow the same way. It draws
//! nothing; a surface renders the field and filters its rows through `matches`.

const std = @import("std");
const theme = @import("../theme/theme.zig");

pub const Colour = theme.Colour;

/// A search field: what the person has typed, and the placeholder shown until they do.
pub const Field = struct {
    query: []const u8 = "",
    placeholder: []const u8,

    pub fn isEmpty(field: Field) bool {
        return field.query.len == 0;
    }

    /// The text to show: the placeholder while empty, the query once typed.
    pub fn displayText(field: Field) []const u8 {
        return if (field.isEmpty()) field.placeholder else field.query;
    }

    /// The text colour: the muted token for the placeholder, the full-strength token for a query.
    pub fn textColour(field: Field) Colour {
        return if (field.isEmpty()) theme.screen_text_muted else theme.screen_text;
    }

    /// Whether `candidate` matches the current query — the list-filter rule. An empty query matches
    /// everything, so a cleared field shows the whole list; otherwise it is a case-insensitive
    /// substring match.
    pub fn matches(field: Field, candidate: []const u8) bool {
        if (field.isEmpty()) return true;
        return std.ascii.indexOfIgnoreCase(candidate, field.query) != null;
    }
};

// --- Tests ---

const testing = std.testing;

test "an empty field shows the muted placeholder and matches everything" {
    const field = Field{ .placeholder = "Search" };
    try testing.expect(field.isEmpty());
    try testing.expectEqualStrings("Search", field.displayText());
    try testing.expect(std.meta.eql(field.textColour(), theme.screen_text_muted));
    try testing.expect(field.matches("anything at all"));
}

test "a typed field shows the query in full-strength text" {
    const field = Field{ .query = "wi-fi", .placeholder = "Search" };
    try testing.expect(!field.isEmpty());
    try testing.expectEqualStrings("wi-fi", field.displayText());
    try testing.expect(std.meta.eql(field.textColour(), theme.screen_text));
}

test "matching is case-insensitive substring, so a list narrows as the person types" {
    const field = Field{ .query = "LIS", .placeholder = "Search" };
    try testing.expect(field.matches("Lisbon")); // case-insensitive
    try testing.expect(field.matches("carlisle")); // substring, anywhere
    try testing.expect(!field.matches("Porto")); // no match narrows it out
}
