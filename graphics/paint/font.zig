//! The interface's real typeface: Sora, drawn from its own outlines.
//!
//! This is the drawing front end over the TrueType rasterizer. It embeds the Sora font
//! (SIL Open Font License — its licence travels in `design/fonts/OFL.txt`) so the
//! typeface is compiled into the binary and needs no file at runtime, and exposes the
//! same small surface the interface already draws through: measure a string, draw it
//! from a baseline, centre it. A regular weight carries body text and a semibold weight
//! carries headings, chosen by size so a caller does not have to ask.
//!
//! Sizes are given as a cap height, the way the rest of the UI is laid out, and mapped
//! to the font's em internally, so switching the interface to this face does not shift
//! every measurement. Each glyph is rasterized on demand into a stack scratch buffer and
//! blended as coverage, so drawing allocates nothing on the heap and matches the
//! allocator-free signature the callers use.

const std = @import("std");
const truetype = @import("truetype.zig");
const fb = @import("framebuffer.zig");
const design = @import("design");

const Framebuffer = fb.Framebuffer;
const Rgba = fb.Rgba;

/// The two weights, parsed once at compile time from the outlines the design layer
/// embeds.
const regular: truetype.Face = truetype.Face.parse(design.fonts.sora_regular) catch unreachable;
const semibold: truetype.Face = truetype.Face.parse(design.fonts.sora_semibold) catch unreachable;

/// Sora's cap height as a fraction of its em. A caller's size is a cap height; the em
/// pixel size is the cap height divided by this, so glyphs come out at the intended
/// visual size.
const cap_ratio: f32 = 0.70;

/// Headings read in the heavier weight; body text in the regular. The threshold is in
/// cap-height pixels.
const semibold_from: f32 = 16.0;

fn faceFor(size_px: f32) truetype.Face {
    return if (size_px >= semibold_from) semibold else regular;
}

fn emSize(size_px: f32) f32 {
    return size_px / cap_ratio;
}

/// The width in pixels a string occupies at a given cap-height size, before drawing.
pub fn measure(letters: []const u8, size_px: f32) f32 {
    const face = faceFor(size_px);
    const scale = emSize(size_px) / @as(f32, @floatFromInt(face.units_per_em));
    var width: f32 = 0;
    var view = std.unicode.Utf8View.initUnchecked(letters);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        width += @as(f32, @floatFromInt(face.advance(face.glyphIndex(cp)))) * scale;
    }
    return width;
}

/// Draws a left-aligned string with its baseline at (x, baseline_y), at the given
/// cap-height size and colour. Returns the x just past the string.
pub fn draw(target: *Framebuffer, x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba) f32 {
    const face = faceFor(size_px);
    const px = emSize(size_px);
    const scale = px / @as(f32, @floatFromInt(face.units_per_em));

    // A stack scratch arena: enough for one UI glyph's edges, ring, and coverage. If a
    // glyph ever needs more, it is skipped rather than drawn from the heap.
    var scratch: [192 * 1024]u8 = undefined;

    var pen = x;
    var view = std.unicode.Utf8View.initUnchecked(letters);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const glyph = face.glyphIndex(cp);
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        if (truetype.rasterize(face, glyph, px, fba.allocator())) |bitmap| {
            var bmp = bitmap;
            blit(target, bmp, pen, baseline_y, colour);
            bmp.deinit(fba.allocator());
        } else |_| {}
        pen += @as(f32, @floatFromInt(face.advance(glyph))) * scale;
    }
    return pen;
}

/// Draws a string centred horizontally on `centre_x`, baseline at `baseline_y`.
pub fn drawCentred(target: *Framebuffer, centre_x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba) void {
    const width = measure(letters, size_px);
    _ = draw(target, centre_x - width / 2.0, baseline_y, letters, size_px, colour);
}

/// Blends a glyph's coverage bitmap onto the target at pen (x, baseline_y).
fn blit(target: *Framebuffer, bitmap: truetype.Bitmap, pen_x: f32, baseline_y: f32, colour: Rgba) void {
    if (bitmap.width == 0 or bitmap.height == 0) return;
    const ox: i32 = @as(i32, @intFromFloat(@round(pen_x))) + bitmap.left;
    const oy: i32 = @as(i32, @intFromFloat(@round(baseline_y))) + bitmap.top;
    var gy: u32 = 0;
    while (gy < bitmap.height) : (gy += 1) {
        const ty = oy + @as(i32, @intCast(gy));
        if (ty < 0 or ty >= @as(i32, @intCast(target.height))) continue;
        var gx: u32 = 0;
        while (gx < bitmap.width) : (gx += 1) {
            const tx = ox + @as(i32, @intCast(gx));
            if (tx < 0 or tx >= @as(i32, @intCast(target.width))) continue;
            const cov = bitmap.coverage[gy * bitmap.width + gx];
            if (cov == 0) continue;
            target.blend(@intCast(tx), @intCast(ty), colour, cov);
        }
    }
}

const testing = std.testing;
const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };

test "measuring is positive and grows with length" {
    try testing.expect(measure("a", 14) > 0);
    try testing.expect(measure("People & agents", 22) > measure("People", 22));
}

test "drawing real glyphs marks pixels and advances the pen" {
    var target = try Framebuffer.init(testing.allocator, 320, 60, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    const end = draw(&target, 6, 44, "People & agents", 22, white);
    try testing.expect(end > 6);

    var lit: u32 = 0;
    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        var x: u32 = 0;
        while (x < target.width) : (x += 1) {
            if (target.get(x, y).r > 180) lit += 1;
        }
    }
    try testing.expect(lit > 200); // real filled glyphs, not a few stroke pixels
}
