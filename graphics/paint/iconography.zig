//! The app icon glyphs: the white line symbols drawn on each tile.
//!
//! Every app tile is the same squircle in a per-app gradient, and what tells them apart is the white
//! symbol on top — a handset, a speech bubble, a waveform. Each glyph is built from the vector
//! primitives (strokes, discs, rings) at a consistent stroke weight and inset, so the whole set reads as
//! one family rather than a collection of unrelated marks. A glyph is defined in a normalized
//! coordinate space over the tile — points in [0,1] — and mapped into the tile's actual rectangle when
//! drawn, so one definition renders crisply at any tile size. Drawing the tile and its glyph together is
//! how a single call produces a finished, on-brand app icon.
//!
//! This module composes the render primitives; it makes no policy decisions.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rgba = fb.Rgba;
const Point = vector.Point;

const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// The apps whose icons this module can draw.
pub const App = enum { phone, messages, calendar, camera, health, agents, files, settings };

/// The gradient a given app's tile uses.
pub fn gradientFor(app: App) theme.Gradient {
    return switch (app) {
        .phone => theme.icon_phone,
        .messages => theme.icon_messages,
        .calendar => theme.icon_calendar,
        .camera => theme.icon_camera,
        .health => theme.icon_health,
        .agents => theme.icon_agents,
        .files => theme.icon_files,
        .settings => theme.icon_settings,
    };
}

/// Maps a normalized glyph point (0..1 over the tile) to a device point.
fn map(rect: paint.Rect, nx: f32, ny: f32) Point {
    return .{
        .x = @as(f32, @floatFromInt(rect.x)) + nx * @as(f32, @floatFromInt(rect.w)),
        .y = @as(f32, @floatFromInt(rect.y)) + ny * @as(f32, @floatFromInt(rect.h)),
    };
}

fn stroke(target: *Framebuffer, rect: paint.Rect, pts: []const [2]f32, w: f32, closed: bool) void {
    var buffer: [24]Point = undefined;
    const count = @min(pts.len, buffer.len);
    for (pts[0..count], 0..) |p, index| buffer[index] = map(rect, p[0], p[1]);
    vector.strokePolyline(target, buffer[0..count], w, white, closed);
}

/// Draws a complete app icon — the squircle tile in its gradient, then its white glyph — into `rect`.
pub fn draw(target: *Framebuffer, rect: paint.Rect, app: App) void {
    const radius = @as(u32, @intCast(rect.w)) * theme.icon_radius_ratio_num / theme.icon_radius_ratio_den;
    const gradient = gradientFor(app);
    paint.paint(target, &.{.{ .rounded_vgradient = .{
        .rect = rect,
        .radius = radius,
        .top = paint.sample(gradient.top),
        .bottom = paint.sample(gradient.bottom),
    } }});

    const side = @as(f32, @floatFromInt(rect.w));
    const w = side * 0.075; // stroke weight, proportional to the tile
    switch (app) {
        .phone => drawPhone(target, rect, w),
        .messages => drawMessages(target, rect, w),
        .calendar => drawCalendar(target, rect, w),
        .camera => drawCamera(target, rect, w),
        .health => drawHealth(target, rect, w),
        .agents => drawAgents(target, rect, w),
        .files => drawFiles(target, rect, w),
        .settings => drawSettings(target, rect, w),
    }
}

fn drawPhone(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A handset: a curved diagonal bar whose round stroke caps form the ear (top-left) and mouth
    // (bottom-right) cups. The slight curve reads as a receiver rather than a straight bar.
    stroke(target, rect, &.{
        .{ 0.36, 0.32 }, .{ 0.33, 0.38 }, .{ 0.40, 0.50 }, .{ 0.52, 0.62 }, .{ 0.64, 0.69 }, .{ 0.70, 0.66 },
    }, w * 1.25, false);
}

fn drawMessages(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A rounded speech bubble outline with a tail.
    stroke(target, rect, &.{
        .{ 0.30, 0.32 }, .{ 0.70, 0.32 }, .{ 0.72, 0.36 }, .{ 0.72, 0.58 },
        .{ 0.70, 0.62 }, .{ 0.44, 0.62 }, .{ 0.36, 0.70 }, .{ 0.38, 0.62 },
        .{ 0.30, 0.62 }, .{ 0.28, 0.58 }, .{ 0.28, 0.36 },
    }, w, true);
}

fn drawCalendar(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A rounded square with a header bar and two eyes — the friendly calendar face.
    stroke(target, rect, &.{ .{ 0.30, 0.34 }, .{ 0.70, 0.34 }, .{ 0.70, 0.68 }, .{ 0.30, 0.68 } }, w, true);
    stroke(target, rect, &.{ .{ 0.30, 0.44 }, .{ 0.70, 0.44 } }, w, false); // header divider
    vector.fillDisc(target, map(rect, 0.42, 0.56).x, map(rect, 0.42, 0.56).y, w * 0.9, white);
    vector.fillDisc(target, map(rect, 0.58, 0.56).x, map(rect, 0.58, 0.56).y, w * 0.9, white);
}

fn drawCamera(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A body with a small top bump and a lens ring.
    stroke(target, rect, &.{ .{ 0.42, 0.34 }, .{ 0.58, 0.34 }, .{ 0.60, 0.38 }, .{ 0.40, 0.38 } }, w, true); // bump
    stroke(target, rect, &.{ .{ 0.28, 0.40 }, .{ 0.72, 0.40 }, .{ 0.72, 0.66 }, .{ 0.28, 0.66 } }, w, true); // body
    vector.strokeCircle(target, map(rect, 0.50, 0.53).x, map(rect, 0.50, 0.53).y, @as(f32, @floatFromInt(rect.w)) * 0.10, w, white);
}

fn drawHealth(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A pulse waveform across the middle.
    stroke(target, rect, &.{
        .{ 0.26, 0.50 }, .{ 0.40, 0.50 }, .{ 0.46, 0.36 }, .{ 0.54, 0.64 }, .{ 0.60, 0.50 }, .{ 0.74, 0.50 },
    }, w * 1.2, false);
}

fn drawAgents(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // Two interlinked rings — agents working together, the "loop" mark.
    const r = @as(f32, @floatFromInt(rect.w)) * 0.11;
    vector.strokeCircle(target, map(rect, 0.42, 0.50).x, map(rect, 0.42, 0.50).y, r, w, white);
    vector.strokeCircle(target, map(rect, 0.58, 0.50).x, map(rect, 0.58, 0.50).y, r, w, white);
}

fn drawFiles(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A document with a folded top-right corner.
    stroke(target, rect, &.{
        .{ 0.34, 0.30 }, .{ 0.58, 0.30 }, .{ 0.66, 0.38 }, .{ 0.66, 0.70 }, .{ 0.34, 0.70 },
    }, w, true);
    stroke(target, rect, &.{ .{ 0.58, 0.30 }, .{ 0.58, 0.38 }, .{ 0.66, 0.38 } }, w, false); // fold
}

fn drawSettings(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // Two horizontal slider tracks at a thinner weight, each with a round knob at a different position,
    // so the pair reads clearly as sliders rather than merging into a blob.
    const track = w * 0.7;
    stroke(target, rect, &.{ .{ 0.26, 0.42 }, .{ 0.74, 0.42 } }, track, false);
    stroke(target, rect, &.{ .{ 0.26, 0.58 }, .{ 0.74, 0.58 } }, track, false);
    // Knobs: a filled disc ringed by the tile gradient is faked by drawing the disc slightly larger
    // than the track; the different x positions are the slider values.
    vector.fillDisc(target, map(rect, 0.40, 0.42).x, map(rect, 0.40, 0.42).y, w * 1.25, white);
    vector.fillDisc(target, map(rect, 0.62, 0.58).x, map(rect, 0.62, 0.58).y, w * 1.25, white);
}

const testing = std.testing;

test "every app draws a tile with a white glyph over its gradient" {
    for (std.enums.values(App)) |app| {
        var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        defer target.deinit();
        draw(&target, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, app);
        // The tile is filled: the centre is not the cleared background.
        const centre = target.get(32, 32);
        try testing.expect(centre.r != 0 or centre.g != 0 or centre.b != 0);
        // Some pixel is near-white, i.e. the glyph was drawn.
        var found_white = false;
        var y: u32 = 0;
        while (y < 64 and !found_white) : (y += 1) {
            var x: u32 = 0;
            while (x < 64) : (x += 1) {
                const p = target.get(x, y);
                if (p.r > 230 and p.g > 230 and p.b > 230) {
                    found_white = true;
                    break;
                }
            }
        }
        try testing.expect(found_white);
    }
}

test "the corners of a tile are clipped by the squircle" {
    var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    draw(&target, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, .phone);
    try testing.expect(target.get(0, 0).r < 128); // corner clipped away
}

test "each app maps to its themed gradient" {
    try testing.expectEqual(theme.icon_phone.top.red, gradientFor(.phone).top.red);
    try testing.expectEqual(theme.icon_settings.bottom.blue, gradientFor(.settings).bottom.blue);
}
