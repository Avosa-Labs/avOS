//! The delivered glyph assets, embedded as bytes so a renderer can draw the designed symbols.
//!
//! The icon set is authored as small `currentColor` SVGs on a 24-grid under `source/glyphs`. This
//! module embeds the ones the interface draws directly — the app-tile symbols — so the graphics layer
//! renders the delivered artwork rather than a hand-built stand-in, and so the bytes on screen are the
//! same asset the icon gate lints. Naming stays semantic: a caller asks for the glyph an app tile shows,
//! not a filename, and an app without a delivered glyph resolves to null so the caller can fall back.
//!
//! This module holds assets. It draws nothing and decides no policy.

const std = @import("std");

// The app-tile symbols, each the delivered 24-grid glyph.
pub const call = @embedFile("source/glyphs/call.svg");
pub const message = @embedFile("source/glyphs/message.svg");
pub const calendar = @embedFile("source/glyphs/calendar-glyph.svg");
pub const camera = @embedFile("source/glyphs/camera-glyph.svg");
pub const agent = @embedFile("source/glyphs/agent.svg");
pub const folder = @embedFile("source/glyphs/folder.svg");
pub const settings = @embedFile("source/glyphs/settings.svg");
pub const location = @embedFile("source/glyphs/location.svg");
pub const running = @embedFile("source/glyphs/running.svg");
pub const file = @embedFile("source/glyphs/file.svg");

test "an embedded glyph carries its SVG payload" {
    // A sanity check that the asset is present and is the designed currentColor SVG.
    try std.testing.expect(call.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, call, "currentColor") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "<circle") != null);
}
