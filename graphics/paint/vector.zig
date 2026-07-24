//! Antialiased vector strokes and discs, the primitives the icon glyphs and UI symbols are drawn from.
//!
//! The tiles carry white line symbols — a handset, a speech bubble, a waveform — and the shell is full
//! of small drawn marks: a toggle, a chevron, a status dot. All of them are strokes or discs, and both
//! are rasterized here by a distance field: for each pixel near the shape, the distance to the shape's
//! ideal geometry is measured, and coverage falls off across the last half-pixel so the edge is smooth
//! rather than stepped. A stroke is the set of points within half its width of a polyline, so measuring
//! distance to the line segments gives round caps and round joins for free — exactly the soft,
//! rounded-stroke look the design uses — with no separate join handling. The work is bounded to each
//! shape's own bounding box expanded by the stroke, so a small glyph touches only a small patch of
//! pixels. Building every symbol from a stroker and a disc keeps the icon set consistent and cheap.
//!
//! Coordinates are in device pixels as floats; the origin is the top-left.

const std = @import("std");
const fb = @import("framebuffer.zig");

const Framebuffer = fb.Framebuffer;
const Rgba = fb.Rgba;

/// A point in device space.
pub const Point = struct { x: f32, y: f32 };

/// The distance from a point to a line segment [a,b].
fn distanceToSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const abx = bx - ax;
    const aby = by - ay;
    const apx = px - ax;
    const apy = py - ay;
    const len2 = abx * abx + aby * aby;
    const t = if (len2 <= 0.0) 0.0 else std.math.clamp((apx * abx + apy * aby) / len2, 0.0, 1.0);
    const cx = ax + t * abx;
    const cy = ay + t * aby;
    const dx = px - cx;
    const dy = py - cy;
    return @sqrt(dx * dx + dy * dy);
}

/// Coverage in [0,255] for a pixel at signed distance `dist` from a shape edge with half-extent `half`.
/// The transition spans one pixel centred on the edge, which is a clean, cheap antialias.
fn coverageAt(dist: f32, half: f32) u8 {
    const c = half + 0.5 - dist;
    if (c <= 0.0) return 0;
    if (c >= 1.0) return 255;
    return @intFromFloat(c * 255.0);
}

/// Strokes a polyline of points with a given width and colour, antialiased, with round caps and joins.
/// `closed` connects the last point back to the first.
pub fn strokePolyline(target: *Framebuffer, points: []const Point, width: f32, colour: Rgba, closed: bool) void {
    if (points.len == 0) return;
    const half = width * 0.5;
    const pad = half + 1.0;

    // Bounding box of the whole polyline, expanded by the stroke.
    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;
    for (points) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const x0: u32 = @intFromFloat(@max(0.0, @floor(min_x - pad)));
    const y0: u32 = @intFromFloat(@max(0.0, @floor(min_y - pad)));
    const x1: u32 = @intFromFloat(@max(0.0, @ceil(max_x + pad)));
    const y1: u32 = @intFromFloat(@max(0.0, @ceil(max_y + pad)));

    const seg_count = if (closed) points.len else points.len - 1;
    var y = y0;
    while (y <= y1 and y < target.height) : (y += 1) {
        var x = x0;
        while (x <= x1 and x < target.width) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var best: f32 = std.math.floatMax(f32);
            var index: usize = 0;
            while (index < seg_count) : (index += 1) {
                const a = points[index];
                const b = points[(index + 1) % points.len];
                const d = distanceToSegment(px, py, a.x, a.y, b.x, b.y);
                if (d < best) best = d;
            }
            const coverage = coverageAt(best, half);
            if (coverage != 0) target.blend(x, y, colour, coverage);
        }
    }
}

/// Fills an antialiased disc centred at (cx,cy) with radius r.
pub fn fillDisc(target: *Framebuffer, cx: f32, cy: f32, r: f32, colour: Rgba) void {
    const pad = r + 1.0;
    const x0: u32 = @intFromFloat(@max(0.0, @floor(cx - pad)));
    const y0: u32 = @intFromFloat(@max(0.0, @floor(cy - pad)));
    const x1: u32 = @intFromFloat(@max(0.0, @ceil(cx + pad)));
    const y1: u32 = @intFromFloat(@max(0.0, @ceil(cy + pad)));
    var y = y0;
    while (y <= y1 and y < target.height) : (y += 1) {
        var x = x0;
        while (x <= x1 and x < target.width) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            const coverage = coverageAt(dist, r);
            if (coverage != 0) target.blend(x, y, colour, coverage);
        }
    }
}

/// Strokes a circle (ring) of radius r and given stroke width.
pub fn strokeCircle(target: *Framebuffer, cx: f32, cy: f32, r: f32, width: f32, colour: Rgba) void {
    const half = width * 0.5;
    const pad = r + half + 1.0;
    const x0: u32 = @intFromFloat(@max(0.0, @floor(cx - pad)));
    const y0: u32 = @intFromFloat(@max(0.0, @floor(cy - pad)));
    const x1: u32 = @intFromFloat(@max(0.0, @ceil(cx + pad)));
    const y1: u32 = @intFromFloat(@max(0.0, @ceil(cy + pad)));
    var y = y0;
    while (y <= y1 and y < target.height) : (y += 1) {
        var x = x0;
        while (x <= x1 and x < target.width) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const dist = @abs(@sqrt(dx * dx + dy * dy) - r); // distance to the ideal ring
            const coverage = coverageAt(dist, half);
            if (coverage != 0) target.blend(x, y, colour, coverage);
        }
    }
}

const testing = std.testing;
const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };

test "a stroked horizontal line covers its centre and fades at the ends" {
    var target = try Framebuffer.init(testing.allocator, 20, 20, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    strokePolyline(&target, &.{ .{ .x = 4, .y = 10 }, .{ .x = 16, .y = 10 } }, 3, white, false);
    // Centre of the line is fully covered.
    try testing.expectEqual(@as(u8, 255), target.get(10, 10).r);
    // Well above the line is untouched.
    try testing.expectEqual(@as(u8, 0), target.get(10, 2).r);
}

test "a filled disc is opaque at its centre and clear well outside" {
    var target = try Framebuffer.init(testing.allocator, 20, 20, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    fillDisc(&target, 10, 10, 5, white);
    try testing.expectEqual(@as(u8, 255), target.get(10, 10).r);
    try testing.expectEqual(@as(u8, 0), target.get(0, 0).r);
}

test "a stroked circle draws a ring: bright on the ring, dark at the centre" {
    var target = try Framebuffer.init(testing.allocator, 24, 24, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    strokeCircle(&target, 12, 12, 7, 2, white);
    try testing.expect(target.get(12, 5).r > 128); // on the ring (top)
    try testing.expectEqual(@as(u8, 0), target.get(12, 12).r); // hollow centre
}

test "a closed polyline joins its last point to its first" {
    var target = try Framebuffer.init(testing.allocator, 20, 20, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    // A triangle; the closing edge (from the third point back to the first) must be drawn.
    strokePolyline(&target, &.{ .{ .x = 4, .y = 4 }, .{ .x = 16, .y = 4 }, .{ .x = 10, .y = 16 } }, 2, white, true);
    // A point on the closing left edge (roughly midway between (10,16) and (4,4)) is covered.
    try testing.expect(target.get(7, 10).r > 100);
}

test "strokes stay within the framebuffer for points near the edge" {
    var target = try Framebuffer.init(testing.allocator, 8, 8, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    // No trap when the stroke would extend past the edges.
    strokePolyline(&target, &.{ .{ .x = -2, .y = 4 }, .{ .x = 10, .y = 4 } }, 4, white, false);
    try testing.expect(target.get(4, 4).r > 128);
}
