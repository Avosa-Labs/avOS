//! Resolving a semantic icon name to its asset, from a closed set, so a surface asks for
//! an icon by meaning and never renders a missing or wrong glyph.
//!
//! Icons are referred to by name across the whole interface — "back", "share", "delete" —
//! and how that name resolves to an actual glyph decides whether the interface is coherent.
//! If the icon set is open, a surface can name an icon that does not exist and get a blank
//! box, or two surfaces can use different glyphs for the same idea because nothing keeps the
//! names honest. So the icon set is closed and semantic: a fixed table maps each meaning to
//! one asset, a name in the table always resolves to the same glyph everywhere it is used,
//! and a name not in the table is refused rather than rendered as a placeholder. The names
//! are meanings, not filenames, so the same "back" arrow can be redrawn for a new style
//! without any surface changing — the meaning is stable even as the asset behind it is not.
//! A closed semantic set is what makes the iconography consistent by construction.
//!
//! This module draws no glyph. It resolves a semantic icon name to its asset identifier
//! against a closed table, as a pure function.

const std = @import("std");

/// The outcome of resolving an icon name.
pub const Resolution = union(enum) {
    /// The name maps to this asset identifier.
    asset: []const u8,
    /// The name is not in the icon set; refused rather than rendered as a placeholder.
    unknown,

    pub fn hasAsset(resolution: Resolution) bool {
        return resolution == .asset;
    }
};

const Entry = struct {
    name: []const u8,
    asset: []const u8,
};

/// The closed semantic icon set. Each name is a meaning that maps to exactly one asset, so
/// the same idea renders the same glyph everywhere. A name absent from this table does not
/// exist as an icon.
const set = [_]Entry{
    .{ .name = "back", .asset = "glyph.arrow.left" },
    .{ .name = "forward", .asset = "glyph.arrow.right" },
    .{ .name = "share", .asset = "glyph.share" },
    .{ .name = "delete", .asset = "glyph.trash" },
    .{ .name = "settings", .asset = "glyph.gear" },
    .{ .name = "search", .asset = "glyph.magnifier" },
    .{ .name = "close", .asset = "glyph.x" },
};

/// Resolves a semantic icon name to its asset identifier.
///
/// A name in the closed set returns its single mapped asset — the same one every time, so
/// the icon is consistent wherever the name is used. A name not in the set is unknown and
/// refused, never rendered as a placeholder box, so a missing icon is a caught error rather
/// than a silent blank in the interface.
pub fn resolve(name: []const u8) Resolution {
    for (set) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return .{ .asset = entry.asset };
    }
    return .unknown;
}

/// Whether a name is a known icon.
pub fn has(name: []const u8) bool {
    return resolve(name).hasAsset();
}

test "a known name resolves to its asset" {
    switch (resolve("back")) {
        .asset => |asset| try std.testing.expectEqualStrings("glyph.arrow.left", asset),
        .unknown => return error.TestUnexpectedResult,
    }
}

test "an unknown name is refused, not rendered as a placeholder" {
    try std.testing.expectEqual(Resolution.unknown, resolve("nonexistent"));
    // A near miss is still unknown.
    try std.testing.expectEqual(Resolution.unknown, resolve("Back"));
    try std.testing.expectEqual(Resolution.unknown, resolve(""));
}

test "the same name always resolves to the same asset" {
    const first = resolve("share");
    const second = resolve("share");
    try std.testing.expectEqualStrings(first.asset, second.asset);
}

test "membership is exact" {
    try std.testing.expect(has("delete"));
    try std.testing.expect(!has("deletee"));
}

test "every name in the set resolves and nothing else does, swept" {
    // The closed-set property: membership is exact and total.
    for (set) |entry| {
        try std.testing.expect(has(entry.name));
        switch (resolve(entry.name)) {
            .asset => |asset| try std.testing.expectEqualStrings(entry.asset, asset),
            .unknown => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(!has("not.an.icon"));
}
