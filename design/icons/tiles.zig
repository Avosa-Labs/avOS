//! The delivered app-tile artwork, embedded as source vectors for the tile renderer.
//!
//! Each app tile is authored as a small SVG under `source/app-tiles`: a squircle filled with a per-app
//! gradient body, a specular highlight, a shade wash, a hairline outline, and the app's white glyph. This
//! module embeds the tiles the interface draws so the graphics layer rasterises the delivered artwork
//! from its own vectors rather than a hand-built stand-in, and so the bytes on screen are the same asset
//! the icon gate lints. A caller asks for a tile by the app it belongs to, not by a filename, and an app
//! without a delivered tile resolves to null so the caller can fall back.
//!
//! This module holds assets. It draws nothing and decides no policy.

const std = @import("std");

pub const agents = @embedFile("source/app-tiles/agents.svg");
pub const settings = @embedFile("source/app-tiles/settings.svg");
pub const messages = @embedFile("source/app-tiles/messages.svg");
pub const phone = @embedFile("source/app-tiles/phone.svg");
pub const calendar = @embedFile("source/app-tiles/calendar.svg");
pub const files = @embedFile("source/app-tiles/files.svg");
pub const contacts = @embedFile("source/app-tiles/contacts.svg");
pub const camera = @embedFile("source/app-tiles/camera.svg");
pub const weather = @embedFile("source/app-tiles/weather.svg");
pub const browser = @embedFile("source/app-tiles/browser.svg");
pub const calculator = @embedFile("source/app-tiles/calculator.svg");
pub const store = @embedFile("source/app-tiles/store.svg");
pub const health = @embedFile("source/app-tiles/health.svg");
pub const mail = @embedFile("source/app-tiles/mail.svg");
pub const notes = @embedFile("source/app-tiles/notes.svg");
pub const maps = @embedFile("source/app-tiles/maps.svg");
pub const tasks = @embedFile("source/app-tiles/tasks.svg");
pub const music = @embedFile("source/app-tiles/music.svg");
pub const wallet = @embedFile("source/app-tiles/wallet.svg");
pub const photos = @embedFile("source/app-tiles/photos.svg");
pub const clock = @embedFile("source/app-tiles/clock.svg");
pub const home = @embedFile("source/app-tiles/home.svg");

test "an embedded tile carries its gradient body and clip path" {
    try std.testing.expect(weather.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, weather, "linearGradient") != null);
    try std.testing.expect(std.mem.indexOf(u8, weather, "clipPath") != null);
    // The delivered body carries the app's fill, not a hand-built stand-in.
    try std.testing.expect(std.mem.indexOf(u8, weather, "url(#body)") != null);
}
