//! A motion scene: the agent-activity card entrance, animated with the shell's spring easing.
//!
//! This turns the easing engine into something visible: the card that names what an agent just did
//! slides up into place and fades in, settling with the design's gentle overshoot rather than snapping.
//! A frame is a pure function of its progress from 0 to 1 — the card's position and opacity are the
//! eased progress applied to a slide and a fade — so the same progress always draws the same frame, and
//! the transition can be rendered as a deterministic sequence. On a device a frame timer advances the
//! progress; here the progress is supplied, so the animation is reproducible frame by frame. It is the
//! reference for how every surface enters: the spring, the slide, the fade, one rasterizer.
//!
//! This module composes the render primitives and the easing; it decides nothing.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const text = @import("text.zig");
const anim = @import("anim.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;

pub const width: u32 = 390;
pub const height: u32 = 844;

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

fn withAlpha(colour: theme.Colour, alpha: u8) fb.Rgba {
    return .{ .r = colour.red, .g = colour.green, .b = colour.blue, .a = alpha };
}

/// Renders one frame of the agent-card entrance at a linear `progress` in [0,1].
///
/// The eased progress drives both a slide — the card rises from below its resting place — and a fade.
/// Because the spring overshoots, the card rises slightly past its mark before settling, which is the
/// motion that reads as a settle rather than a stop.
pub fn renderFrame(target: *Framebuffer, progress: f32) void {
    // Background: the home wallpaper and greeting stay put; only the card animates.
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    _ = text.draw(target, 24, 40, "9:41", 16, s(theme.text_primary));
    _ = text.draw(target, 24, 96, "Good morning", 15, s(theme.text_secondary));
    _ = text.draw(target, 24, 126, "Your day, arranged by agents", 14, s(theme.agent));

    const eased = anim.springEase(progress);
    const rest_y: f32 = 160;
    const enter_offset: f32 = 40; // starts this far below its resting place
    const card_y: i32 = @intFromFloat(rest_y + (1.0 - eased) * enter_offset);
    const alpha = anim.fade(0, 255, progress);

    const card_rect: paint.Rect = .{ .x = 24, .y = card_y, .w = width - 48, .h = 74 };
    paint.paint(target, &.{.{ .rounded = .{ .rect = card_rect, .radius = theme.radius_lg, .colour = withAlpha(theme.surface, alpha) } }});

    const cy: f32 = @floatFromInt(card_y);
    vector.fillDisc(target, 52, cy + 27, 8, withAlpha(theme.agent, alpha));
    _ = text.draw(target, 74, cy + 23, "travel needs a decision", 13, withAlpha(theme.text_primary, alpha));
    _ = text.draw(target, 74, cy + 44, "Held for your approval.", 11, withAlpha(theme.text_secondary, alpha));
}

const testing = std.testing;

test "the first frame is nearly invisible and low; the last is opaque and settled" {
    var early = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer early.deinit();
    renderFrame(&early, 0.0);

    var late = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer late.deinit();
    renderFrame(&late, 1.0);

    // At progress 0 the card region near its resting place (y~170) is barely drawn (transparent);
    // at progress 1 it is a solid surface.
    const early_px = early.get(width / 2, 175);
    const late_px = late.get(width / 2, 175);
    try testing.expect(late_px.r > early_px.r);
}

test "a frame is deterministic for a given progress" {
    var a = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer a.deinit();
    renderFrame(&a, 0.5);
    var b = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer b.deinit();
    renderFrame(&b, 0.5);
    try testing.expectEqualSlices(u8, a.pixels, b.pixels);
}

test "the card settles into place by the final frame" {
    // At progress 1 the eased value is 1, so the card sits at its resting y (160) — the top of the card
    // is a drawn surface there.
    var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer target.deinit();
    renderFrame(&target, 1.0);
    const px = target.get(width / 2, 175);
    try testing.expect(px.r > theme.base.red);
}
