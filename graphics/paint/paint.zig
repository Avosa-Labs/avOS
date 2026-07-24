//! A display list and the painter that executes it onto a framebuffer.
//!
//! The higher layers describe a frame as a list of paint commands — a solid rectangle, a vertical
//! gradient, a rounded or squircle tile — rather than by touching pixels directly, so a frame is a
//! value that can be built, inspected, and diffed before anything is drawn. The painter walks the list
//! in order, compositing each command over what is already there, which makes back-to-front layering the
//! natural default. The work is bounded: each command touches only the pixels inside its own rectangle,
//! straight interiors are filled at full coverage without any per-pixel maths, and only the rounded
//! corners pay for antialiasing — sampled, so an edge is smooth rather than stepped. The corner shape is
//! a superellipse, the squircle the design uses for its tiles, so a painted icon tile has the same
//! continuous curvature as the reference. Describing frames as commands and executing them in one
//! bounded pass is what keeps rendering both legible and cheap.
//!
//! Coordinates are in device pixels with the origin at the top-left.

const std = @import("std");
const fb = @import("framebuffer.zig");
const theme = @import("design").theme;

const Rgba = fb.Rgba;
const Framebuffer = fb.Framebuffer;

/// Converts a design-token colour to a framebuffer sample.
pub fn sample(colour: theme.Colour) Rgba {
    return .{ .r = colour.red, .g = colour.green, .b = colour.blue, .a = colour.alpha };
}

/// An axis-aligned rectangle in device pixels.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
};

/// A single paint command.
pub const Command = union(enum) {
    /// Fill a rectangle with one colour.
    solid: struct { rect: Rect, colour: Rgba },
    /// Fill a rectangle with a vertical gradient from top to bottom.
    vgradient: struct { rect: Rect, top: Rgba, bottom: Rgba },
    /// Fill a rounded rectangle (superellipse corners) with one colour, antialiased.
    rounded: struct { rect: Rect, radius: u32, colour: Rgba },
    /// Fill a rounded rectangle with a vertical gradient — the shape of an icon tile.
    rounded_vgradient: struct { rect: Rect, radius: u32, top: Rgba, bottom: Rgba },
};

/// Executes a display list onto a framebuffer, in order.
pub fn paint(target: *Framebuffer, commands: []const Command) void {
    for (commands) |command| {
        switch (command) {
            .solid => |c| fillSolid(target, c.rect, c.colour),
            .vgradient => |c| fillVGradient(target, c.rect, c.top, c.bottom),
            .rounded => |c| fillRounded(target, c.rect, c.radius, c.colour, null),
            .rounded_vgradient => |c| fillRounded(target, c.rect, c.radius, c.top, c.bottom),
        }
    }
}

fn clampBounds(target: Framebuffer, rect: Rect) struct { x0: u32, y0: u32, x1: u32, y1: u32 } {
    const x0: i64 = @max(0, rect.x);
    const y0: i64 = @max(0, rect.y);
    const x1: i64 = @min(@as(i64, rect.x) + rect.w, target.width);
    const y1: i64 = @min(@as(i64, rect.y) + rect.h, target.height);
    return .{
        .x0 = @intCast(@max(0, x0)),
        .y0 = @intCast(@max(0, y0)),
        .x1 = @intCast(@max(x0, x1)),
        .y1 = @intCast(@max(y0, y1)),
    };
}

fn fillSolid(target: *Framebuffer, rect: Rect, colour: Rgba) void {
    const b = clampBounds(target.*, rect);
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        var x = b.x0;
        while (x < b.x1) : (x += 1) target.blend(x, y, colour, 255);
    }
}

/// Linearly interpolates one channel between two values by t in [0,1] scaled as num/den.
fn lerp(a: u8, c: u8, num: u32, den: u32) u8 {
    const av = @as(i32, a);
    const cv = @as(i32, c);
    return @intCast(av + @divTrunc((cv - av) * @as(i32, @intCast(num)), @as(i32, @intCast(den))));
}

fn gradientAt(top: Rgba, bottom: Rgba, row: u32, height: u32) Rgba {
    const den = if (height <= 1) 1 else height - 1;
    return .{
        .r = lerp(top.r, bottom.r, row, den),
        .g = lerp(top.g, bottom.g, row, den),
        .b = lerp(top.b, bottom.b, row, den),
        .a = lerp(top.a, bottom.a, row, den),
    };
}

fn fillVGradient(target: *Framebuffer, rect: Rect, top: Rgba, bottom: Rgba) void {
    const b = clampBounds(target.*, rect);
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        const row = y - @as(u32, @intCast(@max(0, rect.y)));
        const colour = gradientAt(top, bottom, row, rect.h);
        var x = b.x0;
        while (x < b.x1) : (x += 1) target.blend(x, y, colour, 255);
    }
}

/// Superellipse (squircle) inside test at exponent 4: a point at corner-relative distance (dx,dy) from
/// a corner centre with radius r is inside when (dx/r)^4 + (dy/r)^4 <= 1.
fn insideCorner(dx: f32, dy: f32, r: f32) bool {
    const nx = dx / r;
    const ny = dy / r;
    const nx2 = nx * nx;
    const ny2 = ny * ny;
    return nx2 * nx2 + ny2 * ny2 <= 1.0;
}

/// Coverage in [0,255] of a corner pixel, by a 4x4 supersample against the superellipse.
fn cornerCoverage(px: f32, py: f32, cx: f32, cy: f32, r: f32) u8 {
    var inside: u32 = 0;
    var sy: u8 = 0;
    while (sy < 4) : (sy += 1) {
        var sx: u8 = 0;
        while (sx < 4) : (sx += 1) {
            const sample_x = px + (@as(f32, @floatFromInt(sx)) + 0.5) / 4.0;
            const sample_y = py + (@as(f32, @floatFromInt(sy)) + 0.5) / 4.0;
            const dx = @abs(sample_x - cx);
            const dy = @abs(sample_y - cy);
            if (insideCorner(dx, dy, r)) inside += 1;
        }
    }
    return @intCast(inside * 255 / 16);
}

/// Fills a rounded/squircle rectangle. Straight interior pixels are full coverage; only the four corner
/// bands are supersampled. If `bottom` is non-null the fill is a vertical gradient.
fn fillRounded(target: *Framebuffer, rect: Rect, radius_in: u32, top: Rgba, bottom: ?Rgba) void {
    const b = clampBounds(target.*, rect);
    // Radius cannot exceed half the shorter side.
    const radius = @min(radius_in, @min(rect.w, rect.h) / 2);
    const rf = @as(f32, @floatFromInt(radius));
    const left = rect.x;
    const top_y = rect.y;
    const right = rect.x + @as(i32, @intCast(rect.w));
    const bottom_y = rect.y + @as(i32, @intCast(rect.h));

    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        const row = y - @as(u32, @intCast(@max(0, rect.y)));
        const colour = if (bottom) |bot| gradientAt(top, bot, row, rect.h) else top;
        const iy: i32 = @intCast(y);
        var x = b.x0;
        while (x < b.x1) : (x += 1) {
            const ix: i32 = @intCast(x);
            // Which corner, if any, is this pixel in?
            var cx: f32 = 0;
            var cy: f32 = 0;
            var in_corner = false;
            if (ix < left + @as(i32, @intCast(radius)) and iy < top_y + @as(i32, @intCast(radius))) {
                cx = @floatFromInt(left + @as(i32, @intCast(radius)));
                cy = @floatFromInt(top_y + @as(i32, @intCast(radius)));
                in_corner = true;
            } else if (ix >= right - @as(i32, @intCast(radius)) and iy < top_y + @as(i32, @intCast(radius))) {
                cx = @floatFromInt(right - @as(i32, @intCast(radius)));
                cy = @floatFromInt(top_y + @as(i32, @intCast(radius)));
                in_corner = true;
            } else if (ix < left + @as(i32, @intCast(radius)) and iy >= bottom_y - @as(i32, @intCast(radius))) {
                cx = @floatFromInt(left + @as(i32, @intCast(radius)));
                cy = @floatFromInt(bottom_y - @as(i32, @intCast(radius)));
                in_corner = true;
            } else if (ix >= right - @as(i32, @intCast(radius)) and iy >= bottom_y - @as(i32, @intCast(radius))) {
                cx = @floatFromInt(right - @as(i32, @intCast(radius)));
                cy = @floatFromInt(bottom_y - @as(i32, @intCast(radius)));
                in_corner = true;
            }
            if (in_corner and radius > 0) {
                const coverage = cornerCoverage(@floatFromInt(ix), @floatFromInt(iy), cx, cy, rf);
                target.blend(x, y, colour, coverage);
            } else {
                target.blend(x, y, colour, 255);
            }
        }
    }
}

const testing = std.testing;

test "a solid command fills its rectangle" {
    var target = try Framebuffer.init(testing.allocator, 10, 10, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    paint(&target, &.{.{ .solid = .{ .rect = .{ .x = 2, .y = 2, .w = 4, .h = 4 }, .colour = .{ .r = 255, .g = 0, .b = 0, .a = 255 } } }});
    try testing.expectEqual(@as(u8, 255), target.get(3, 3).r);
    try testing.expectEqual(@as(u8, 0), target.get(0, 0).r); // outside untouched
    try testing.expectEqual(@as(u8, 0), target.get(6, 6).r); // just outside
}

test "a vertical gradient interpolates top to bottom" {
    var target = try Framebuffer.init(testing.allocator, 4, 5, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    paint(&target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = 4, .h = 5 },
        .top = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .bottom = .{ .r = 200, .g = 0, .b = 0, .a = 255 },
    } }});
    try testing.expectEqual(@as(u8, 0), target.get(0, 0).r);
    try testing.expectEqual(@as(u8, 200), target.get(0, 4).r);
    const mid = target.get(0, 2).r;
    try testing.expect(mid > 80 and mid < 120);
}

test "a rounded rect clips its corners but fills its centre" {
    var target = try Framebuffer.init(testing.allocator, 20, 20, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    paint(&target, &.{.{ .rounded = .{
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .radius = 8,
        .colour = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    } }});
    // Centre is filled.
    try testing.expectEqual(@as(u8, 255), target.get(10, 10).r);
    // The extreme corner pixel is (mostly) clipped away.
    try testing.expect(target.get(0, 0).r < 128);
}

test "an icon-tile gradient fills the centre and rounds the corners" {
    var target = try Framebuffer.init(testing.allocator, 24, 24, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    paint(&target, &.{.{ .rounded_vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = 24, .h = 24 },
        .radius = 6,
        .top = sample(theme.icon_calendar.top),
        .bottom = sample(theme.icon_calendar.bottom),
    } }});
    try testing.expect(target.get(12, 2).r > target.get(12, 22).r); // lighter at top
    try testing.expect(target.get(0, 0).r < 128); // corner clipped
}

test "painting is bounded to the framebuffer for an oversized rect" {
    var target = try Framebuffer.init(testing.allocator, 4, 4, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    // No trap despite the rect exceeding the framebuffer in every direction.
    paint(&target, &.{.{ .solid = .{ .rect = .{ .x = -10, .y = -10, .w = 100, .h = 100 }, .colour = .{ .r = 9, .g = 9, .b = 9, .a = 255 } } }});
    try testing.expectEqual(@as(u8, 9), target.get(0, 0).r);
    try testing.expectEqual(@as(u8, 9), target.get(3, 3).r);
}
