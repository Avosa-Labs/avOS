//! The seam a text shaper sits behind: the interface that turns a run of characters
//! into positioned glyphs, so the layout above it does not care whether the shaper is
//! the on-device geometric font or a full shaping engine for the world's scripts.
//!
//! Shaping — deciding which glyphs a run of text becomes and how far each advances — is
//! not something to hand-roll for a consumer OS. The moment text must handle the
//! scripts real people write in, it needs ligatures, contextual forms, combining
//! marks, and bidirectional ordering, and that is a shaping library's job, not a
//! rewrite waiting to fail. So shaping is defined here as an interface, and the rest of
//! the text stack depends only on the interface: a `Font` reports its vertical metrics
//! and a codepoint's advance, and a `Shaper` turns a run into positioned glyphs. The
//! device ships two implementations behind this one seam — a simple geometric font for
//! the boot and recovery paths, where depending on no external library is a feature,
//! and a shaping engine (HarfBuzz over FreeType outlines) for everything else, which
//! this interface is shaped to accept without the layout layer knowing the difference.
//!
//! This module shapes nothing itself in the general case. It defines the interface and
//! provides a simple metric-driven shaper for left-to-right runs, over which the layout
//! layer builds; a full shaper is a native adapter that satisfies the same interface.

const std = @import("std");

/// A font's vertical metrics, in the same units as its advances. Ascent is above the
/// baseline, descent below (a positive magnitude), and line gap is the extra leading
/// between lines. Together they fix how tall a line is and where its baseline sits.
pub const Metrics = struct {
    ascent: f32,
    descent: f32,
    line_gap: f32 = 0,

    /// The height of one line: ascent plus descent plus the line gap.
    pub fn lineHeight(metrics: Metrics) f32 {
        return metrics.ascent + metrics.descent + metrics.line_gap;
    }
};

/// A font behind the shaping seam: its metrics and the advance of a single codepoint.
/// The geometric font and a native shaper's font both present this same face.
pub const Font = struct {
    context: *const anyopaque,
    metrics: Metrics,
    /// The advance width of a codepoint in font units. A codepoint the font does not
    /// have returns the advance of its fallback (its missing-glyph box), never zero,
    /// so an unknown character still takes space rather than overlapping its neighbour.
    advance_fn: *const fn (context: *const anyopaque, codepoint: u21) f32,

    pub fn advance(font: Font, codepoint: u21) f32 {
        return font.advance_fn(font.context, codepoint);
    }
};

/// One positioned glyph in a shaped run: which source character it came from (its
/// cluster, so selection and editing can map back), and where it sits along the run.
pub const PositionedGlyph = struct {
    codepoint: u21,
    /// The byte offset in the source text this glyph belongs to — its cluster. A
    /// shaper that merges characters into one glyph gives them the same cluster.
    cluster: usize,
    /// The glyph's left edge along the run, in font units from the run's start.
    x: f32,
    advance: f32,
};

/// A shaped run: its glyphs, positioned, and the total width it advances.
pub const Run = struct {
    glyphs: []const PositionedGlyph,
    width: f32,
};

/// Shapes a left-to-right run into positioned glyphs, scaled to `size` (font units are
/// multiplied so the advances come out in the size's units), writing into a
/// caller-owned buffer.
///
/// This is the simple shaper the metric-driven fonts use: one glyph per codepoint,
/// advancing left to right, clusters at byte offsets. It handles the scripts whose
/// shaping is a straight sequence of advances — which the geometric font is limited to
/// — and it is deliberately not a general shaper: a script needing reordering or
/// ligatures is served by a native shaper behind the same `Run` result, so the layout
/// layer above sees no difference.
pub fn shapeSimple(font: Font, text: []const u8, size: f32, buffer: []PositionedGlyph) !Run {
    const scale = size / font.metrics.ascent; // ascent maps to the requested cap-ish size
    var pen: f32 = 0;
    var count: usize = 0;
    var view = try std.unicode.Utf8View.init(text);
    var iterator = view.iterator();
    var byte_index: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        if (count >= buffer.len) break;
        const glyph_advance = font.advance(codepoint) * scale;
        buffer[count] = .{ .codepoint = codepoint, .cluster = byte_index, .x = pen, .advance = glyph_advance };
        pen += glyph_advance;
        count += 1;
        byte_index += std.unicode.utf8CodepointSequenceLength(codepoint) catch 1;
    }
    return .{ .glyphs = buffer[0..count], .width = pen };
}

// --- A simple monospace test font, so the shaper and layout can be exercised without
// the full geometric glyph table. ---

const mono_advance: f32 = 6;

fn monoAdvance(_: *const anyopaque, _: u21) f32 {
    return mono_advance;
}

/// A fixed-advance font for tests and for the earliest boot text, where a predictable
/// metric matters more than a proportional one.
pub const mono: Font = .{
    .context = undefined,
    .metrics = .{ .ascent = 7, .descent = 2, .line_gap = 1 },
    .advance_fn = monoAdvance,
};

// --- Tests ---

const testing = std.testing;

test "a run's glyphs advance left to right and sum to its width" {
    var buffer: [16]PositionedGlyph = undefined;
    const run = try shapeSimple(mono, "abc", 14, &buffer);
    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    // Each glyph starts where the previous ended.
    try testing.expectEqual(@as(f32, 0), run.glyphs[0].x);
    try testing.expectApproxEqAbs(run.glyphs[0].advance, run.glyphs[1].x, 1e-6);
    // The width is the sum of the advances.
    var total: f32 = 0;
    for (run.glyphs) |glyph| total += glyph.advance;
    try testing.expectApproxEqAbs(total, run.width, 1e-5);
}

test "clusters map each glyph back to its source byte" {
    var buffer: [16]PositionedGlyph = undefined;
    const run = try shapeSimple(mono, "hi", 14, &buffer);
    try testing.expectEqual(@as(usize, 0), run.glyphs[0].cluster);
    try testing.expectEqual(@as(usize, 1), run.glyphs[1].cluster);
}

test "a multi-byte codepoint advances the cluster by its byte length" {
    var buffer: [16]PositionedGlyph = undefined;
    // "a€b": the euro sign is three bytes, so the following glyph's cluster is at 4.
    const run = try shapeSimple(mono, "a\u{20AC}b", 14, &buffer);
    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try testing.expectEqual(@as(usize, 0), run.glyphs[0].cluster);
    try testing.expectEqual(@as(usize, 1), run.glyphs[1].cluster);
    try testing.expectEqual(@as(usize, 4), run.glyphs[2].cluster);
}

test "line height combines ascent, descent, and gap" {
    try testing.expectApproxEqAbs(@as(f32, 10), mono.metrics.lineHeight(), 1e-6);
}

test "the shaper stops cleanly at the buffer bound" {
    var buffer: [2]PositionedGlyph = undefined;
    const run = try shapeSimple(mono, "abcdef", 14, &buffer);
    try testing.expectEqual(@as(usize, 2), run.glyphs.len);
}
