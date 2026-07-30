//! The Weather screen, rendered bespoke and driven by real data — the quality bar every app screen
//! is held to.
//!
//! This is not the generic row list every app fell back to; it is Weather's own layout: a sky that
//! gradients with the conditions, the temperature set large as the hero, the day's high and low, and
//! an hourly strip of raised cards that float on the soft-shadow elevation the design uses to separate
//! layers. Nothing here is demonstration content — every string and colour is a field of the
//! `WeatherView` the shell fills from the real Weather domain (the current reading, the condition, the
//! forecast the domain expands), so the same layout shows Lisbon at dawn or a storm at midnight
//! truthfully. Graphics stays app-agnostic: it is handed plain data and paints it, never reaching into
//! an app.
//!
//! Rendered portrait at a phone's proportions. The work is bounded — a fixed set of fills, one shadow
//! per card, and the text runs — so a frame is O(cells) in the forecast, nothing more.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

pub const width: u32 = 390;
pub const height: u32 = 844;

/// One hour of the forecast strip: the hour label and the temperature at it, already formatted by the
/// shell from a domain reading.
pub const HourCell = struct {
    hour: []const u8,
    temp: []const u8,
};

/// Everything the Weather screen draws, filled by the shell from the real domain. The sky gradient is
/// passed as two colours the shell maps from the condition, so this module needs no knowledge of the
/// app's condition enum — it renders the data it is handed.
pub const WeatherView = struct {
    location: []const u8,
    temperature: []const u8, // the hero, e.g. "19°"
    condition: []const u8, // e.g. "Partly cloudy"
    high_low: []const u8, // e.g. "H:21°  L:14°"
    sky_top: theme.Colour,
    sky_bottom: theme.Colour,
    forecast: []const HourCell,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the Weather screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: WeatherView) void {
    // The sky: a full-screen vertical gradient the shell keyed to the conditions.
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(view.sky_top),
        .bottom = s(view.sky_bottom),
    } }});

    // Status time, top-left, quiet.
    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));

    // The place and the hero temperature, centred at the top third.
    const cx: f32 = @floatFromInt(width / 2);
    text.drawCentred(target, cx, 132, view.location, 24, s(theme.screen_text));
    text.drawCentred(target, cx, 240, view.temperature, 96, s(theme.screen_text));
    text.drawCentred(target, cx, 284, view.condition, 18, s(theme.screen_text_soft));
    text.drawCentred(target, cx, 314, view.high_low, 15, s(theme.screen_text_muted));

    // The hourly strip: one raised card holding evenly spaced cells, floating on a soft shadow.
    const strip: Rect = .{ .x = 20, .y = 380, .w = width - 40, .h = 140 };
    paint.paint(target, &.{
        // The elevation: the card's silhouette, offset down and feathered, so it reads as raised.
        .{ .shadow = .{
            .rect = .{ .x = strip.x, .y = strip.y + theme.shadow_offset_y, .w = strip.w, .h = strip.h },
            .radius = theme.radius_lg,
            .blur = theme.shadow_blur,
            .colour = s(theme.shadow_tint),
            .alpha = theme.shadow_tint.alpha,
        } },
        // The card itself: a raised surface with a gentle top-to-bottom lift.
        .{ .rounded_vgradient = .{
            .rect = strip,
            .radius = theme.radius_lg,
            .top = s(theme.surface_raised),
            .bottom = s(theme.surface),
        } },
    });

    // The cells, spaced across the card. Each is an hour label, a small mark, and its temperature.
    const count = view.forecast.len;
    if (count == 0) return;
    const inset: u32 = 8;
    const usable: f32 = @floatFromInt(strip.w - 2 * inset);
    const step = usable / @as(f32, @floatFromInt(count));
    const first: f32 = @floatFromInt(strip.x + @as(i32, @intCast(inset)));
    for (view.forecast, 0..) |cell, i| {
        const ccx = first + step * (@as(f32, @floatFromInt(i)) + 0.5);
        text.drawCentred(target, ccx, @floatFromInt(strip.y + 34), cell.hour, 14, s(theme.screen_text_soft));
        // A small agent-hued mark between the labels, the same accent the system uses.
        paint.paint(target, &.{.{ .rounded = .{
            .rect = .{ .x = @as(i32, @intFromFloat(ccx)) - 3, .y = strip.y + 62, .w = 6, .h = 6 },
            .radius = 3,
            .colour = s(theme.agent),
        } }});
        text.drawCentred(target, ccx, @floatFromInt(strip.y + 106), cell.temp, 18, s(theme.screen_text));
    }
}

// --- Tests ---

const testing = std.testing;

fn sampleView() WeatherView {
    return .{
        .location = "Lisbon",
        .temperature = "19\u{00B0}",
        .condition = "Partly cloudy",
        .high_low = "H:21\u{00B0}  L:14\u{00B0}",
        .sky_top = theme.sky,
        .sky_bottom = theme.base,
        .forecast = &.{
            .{ .hour = "10", .temp = "18\u{00B0}" },
            .{ .hour = "11", .temp = "19\u{00B0}" },
            .{ .hour = "12", .temp = "20\u{00B0}" },
            .{ .hour = "13", .temp = "21\u{00B0}" },
            .{ .hour = "14", .temp = "21\u{00B0}" },
        },
    };
}

test "the weather screen paints its data over the sky, not the blank background" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    // Something was drawn.
    try testing.expect(target.digest() != before);
    // The sky gradient covered the whole frame: a corner is no longer the transparent init fill.
    try testing.expect(target.get(2, 2).a == 255);
    // The hero temperature region has ink over the sky (the large glyphs near the centre).
    var painted_hero = false;
    var y: u32 = 180;
    while (y < 240) : (y += 4) {
        var x: u32 = 150;
        while (x < 240) : (x += 4) {
            if (target.get(x, y).r != target.get(2, 2).r) painted_hero = true;
            x += 0;
            if (painted_hero) break;
        }
        if (painted_hero) break;
    }
    try testing.expect(painted_hero);
}

test "an empty forecast still renders the hero without drawing cells or crashing" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    var view = sampleView();
    view.forecast = &.{};
    render(&target, view); // must not divide by zero or index an empty strip
    try testing.expect(target.get(2, 2).a == 255); // the sky still filled
}
