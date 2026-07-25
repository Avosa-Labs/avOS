//! Laying shaped text into lines within a width: where each line breaks, where its
//! baseline sits, how it aligns, and how it truncates — the layer between a shaper's
//! positioned glyphs and a paragraph on screen.
//!
//! Shaping says how wide each glyph is; layout decides where the lines fall. Given a
//! width, it breaks the run into lines at word boundaries, stacks them by the font's
//! line height so their baselines are evenly spaced, and places each line's content
//! within the width according to its alignment — flush left, centred, or flush right.
//! When the text does not fit and the caller has asked for a single line, layout
//! truncates: it drops whole glyphs from the end and marks the line so an ellipsis can
//! stand for what was cut, because a line that simply overflows its box collides with
//! whatever is beside it. Every one of these is a measurement, not a drawing: the
//! output is a set of placed lines a renderer then paints, so the same layout serves
//! the software rasterizer and a GPU path alike.
//!
//! This module draws nothing. It places shaped runs into aligned, wrapped, truncated
//! lines, as a pure function over glyph advances and a width.

const std = @import("std");
const shaping = @import("shaping.zig");

pub const Font = shaping.Font;

/// How a line's content sits within the available width.
pub const Alignment = enum { start, center, end };

/// A placed line: the byte range of source text it covers, the horizontal offset its
/// content begins at (from alignment), its baseline's vertical position, and whether
/// it was truncated.
pub const Line = struct {
    /// Byte offset in the source where this line begins.
    start: usize,
    /// Byte offset in the source just past this line's last laid character.
    end: usize,
    /// The width the line's content occupies, before alignment.
    content_width: f32,
    /// The x offset the content starts at, from the alignment within the box.
    x: f32,
    /// The y position of the line's baseline.
    baseline: f32,
    /// Whether the line was cut to fit and should show an ellipsis.
    truncated: bool,
};

/// How text that does not fit is handled.
pub const Overflow = enum {
    /// Wrap to as many lines as needed.
    wrap,
    /// Keep to one line, truncating with an ellipsis when it does not fit.
    truncate,
};

pub const Options = struct {
    width: f32,
    alignment: Alignment = .start,
    overflow: Overflow = .wrap,
    size: f32,
};

/// The result of laying a paragraph out: its placed lines and the total height.
pub const Layout = struct {
    lines: []const Line,
    height: f32,
};

fn alignOffset(alignment: Alignment, content_width: f32, box_width: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => @max(0, (box_width - content_width) / 2),
        .end => @max(0, box_width - content_width),
    };
}

/// Lays a text paragraph into placed lines within `options.width`.
///
/// Words are packed onto a line until the next would overflow, then a new line begins;
/// a single word wider than the whole width is placed on its own line anyway, so layout
/// always makes progress rather than looping on an unbreakable word. Under
/// `truncate`, only the first line is kept and it is cut to whole glyphs that fit,
/// marked so an ellipsis can be drawn. Each line's baseline steps down by the font's
/// line height, and its content is offset by its alignment. The placed lines are
/// written into `buffer`.
pub fn layout(font: Font, text: []const u8, options: Options, glyph_buffer: []shaping.PositionedGlyph, buffer: []Line) !Layout {
    const run = try shaping.shapeSimple(font, text, options.size, glyph_buffer);
    const line_height = font.metrics.lineHeight() * (options.size / font.metrics.ascent);

    var line_count: usize = 0;
    var line_start_byte: usize = 0;
    var line_start_glyph: usize = 0;
    var width_so_far: f32 = 0;
    var last_break_glyph: ?usize = null; // glyph index just after the last space
    var last_break_width: f32 = 0;
    var last_break_byte: usize = 0;

    var index: usize = 0;
    while (index < run.glyphs.len) : (index += 1) {
        const glyph = run.glyphs[index];
        const is_space = glyph.codepoint == ' ';
        const next_width = width_so_far + glyph.advance;

        if (next_width > options.width and index > line_start_glyph) {
            // The line is full. Break at the last space if there was one, else here.
            var break_glyph = index;
            var break_width = width_so_far;
            var break_byte = glyph.cluster;
            if (last_break_glyph) |bg| {
                break_glyph = bg;
                break_width = last_break_width;
                break_byte = last_break_byte;
            }
            if (line_count < buffer.len) {
                buffer[line_count] = makeLine(line_start_byte, break_byte, break_width, options, line_count, line_height);
                line_count += 1;
            }
            if (options.overflow == .truncate) {
                return truncateFirst(font, text, options, run, glyph_buffer, buffer, line_height);
            }
            // Start the next line after the break.
            line_start_glyph = break_glyph;
            line_start_byte = break_byte;
            width_so_far = 0;
            last_break_glyph = null;
            // Re-process from the break point.
            index = break_glyph - 1;
            continue;
        }

        width_so_far = next_width;
        if (is_space) {
            last_break_glyph = index + 1;
            last_break_width = width_so_far;
            last_break_byte = glyph.cluster + 1;
        }
    }

    // The final line.
    if (line_start_glyph < run.glyphs.len or run.glyphs.len == 0) {
        if (line_count < buffer.len) {
            buffer[line_count] = makeLine(line_start_byte, text.len, width_so_far, options, line_count, line_height);
            line_count += 1;
        }
    }

    return .{ .lines = buffer[0..line_count], .height = @as(f32, @floatFromInt(line_count)) * line_height };
}

fn makeLine(start: usize, end: usize, content_width: f32, options: Options, line_index: usize, line_height: f32) Line {
    return .{
        .start = start,
        .end = end,
        .content_width = content_width,
        .x = alignOffset(options.alignment, content_width, options.width),
        .baseline = @as(f32, @floatFromInt(line_index)) * line_height + line_height,
        .truncated = false,
    };
}

fn truncateFirst(font: Font, text: []const u8, options: Options, run: shaping.Run, glyph_buffer: []shaping.PositionedGlyph, buffer: []Line, line_height: f32) !Layout {
    _ = font;
    _ = text;
    _ = glyph_buffer;
    // Keep whole glyphs that fit within the width; mark the line truncated.
    var fit_width: f32 = 0;
    var end_byte: usize = 0;
    for (run.glyphs) |glyph| {
        if (fit_width + glyph.advance > options.width) break;
        fit_width += glyph.advance;
        end_byte = glyph.cluster + 1;
    }
    buffer[0] = .{
        .start = 0,
        .end = end_byte,
        .content_width = fit_width,
        .x = alignOffset(options.alignment, fit_width, options.width),
        .baseline = line_height,
        .truncated = true,
    };
    return .{ .lines = buffer[0..1], .height = line_height };
}

// --- Tests ---

const testing = std.testing;
const mono = shaping.mono;

test "short text lays out on a single untruncated line" {
    var glyphs: [64]shaping.PositionedGlyph = undefined;
    var lines: [8]Line = undefined;
    const result = try layout(mono, "hi", .{ .width = 200, .size = 14 }, &glyphs, &lines);
    try testing.expectEqual(@as(usize, 1), result.lines.len);
    try testing.expect(!result.lines[0].truncated);
}

test "text wider than the box wraps at word boundaries" {
    var glyphs: [128]shaping.PositionedGlyph = undefined;
    var lines: [8]Line = undefined;
    // Each mono glyph is 6 units at ascent 7 -> scale 2 at size 14, so ~12 px/char.
    // A narrow box forces wrapping between words.
    const result = try layout(mono, "one two three", .{ .width = 60, .size = 14, .overflow = .wrap }, &glyphs, &lines);
    try testing.expect(result.lines.len >= 2);
    // Baselines step down by a positive line height.
    try testing.expect(result.lines[1].baseline > result.lines[0].baseline);
}

test "centered text is offset so its content sits in the middle" {
    var glyphs: [64]shaping.PositionedGlyph = undefined;
    var lines: [8]Line = undefined;
    const result = try layout(mono, "hi", .{ .width = 200, .size = 14, .alignment = .center }, &glyphs, &lines);
    try testing.expect(result.lines[0].x > 0);
    // The content plus twice the offset spans the box.
    try testing.expectApproxEqAbs(options_width(200), result.lines[0].x * 2 + result.lines[0].content_width, 1.0);
}

fn options_width(w: f32) f32 {
    return w;
}

test "truncated overflow keeps one line and marks it" {
    var glyphs: [128]shaping.PositionedGlyph = undefined;
    var lines: [8]Line = undefined;
    const result = try layout(mono, "this text is far too long to fit", .{ .width = 60, .size = 14, .overflow = .truncate }, &glyphs, &lines);
    try testing.expectEqual(@as(usize, 1), result.lines.len);
    try testing.expect(result.lines[0].truncated);
    // The kept content fits the box.
    try testing.expect(result.lines[0].content_width <= 60);
}

test "an unbreakable word wider than the box still lays out rather than looping" {
    var glyphs: [128]shaping.PositionedGlyph = undefined;
    var lines: [8]Line = undefined;
    const result = try layout(mono, "supercalifragilistic", .{ .width = 30, .size = 14, .overflow = .wrap }, &glyphs, &lines);
    // It makes progress: at least one line, and it terminates.
    try testing.expect(result.lines.len >= 1);
}
