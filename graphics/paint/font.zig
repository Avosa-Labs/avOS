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
//! every measurement. A glyph is rasterized from its outline once into a bounded coverage
//! cache (see below) and blitted from there on every later frame, so a warm frame allocates
//! nothing on the heap and re-rasterizes nothing, matching the allocator-free signature the
//! callers use.

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

/// The weight a caller wants. `auto` chooses by size — headings heavier, body regular — so a caller
/// that does not care need not ask; `regular` and `semibold` pin the weight when the design specifies
/// one the size heuristic would get wrong (a large but light prompt, a small but bold label).
pub const Weight = enum { auto, regular, semibold };

fn faceForWeight(size_px: f32, weight: Weight) truetype.Face {
    return selectFace(size_px, weight).face;
}

/// A chosen face paired with a stable one-byte id, so a glyph's cache key can name its face
/// without hashing the whole `Face` struct. `id` is 0 for the regular weight, 1 for semibold.
const Selected = struct { face: truetype.Face, id: u8 };

fn selectFace(size_px: f32, weight: Weight) Selected {
    return switch (weight) {
        .auto => if (size_px >= semibold_from) .{ .face = semibold, .id = 1 } else .{ .face = regular, .id = 0 },
        .regular => .{ .face = regular, .id = 0 },
        .semibold => .{ .face = semibold, .id = 1 },
    };
}

fn emSize(size_px: f32) f32 {
    return size_px / cap_ratio;
}

/// The width in pixels a string occupies at a given cap-height size, before drawing.
pub fn measure(letters: []const u8, size_px: f32) f32 {
    return measureWeighted(letters, size_px, .auto);
}

/// `measure` at an explicit weight, so measurement matches a pinned-weight draw.
pub fn measureWeighted(letters: []const u8, size_px: f32, weight: Weight) f32 {
    const face = faceForWeight(size_px, weight);
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
    return drawWeighted(target, x, baseline_y, letters, size_px, colour, .auto);
}

/// `draw` at an explicit weight, for text whose design weight the size heuristic would get wrong.
pub fn drawWeighted(target: *Framebuffer, x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba, weight: Weight) f32 {
    const sel = selectFace(size_px, weight);
    const px = emSize(size_px);
    const scale = px / @as(f32, @floatFromInt(sel.face.units_per_em));

    var pen = x;
    var view = std.unicode.Utf8View.initUnchecked(letters);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const glyph = sel.face.glyphIndex(cp);
        emit(target, sel, glyph, px, pen, baseline_y, colour);
        pen += @as(f32, @floatFromInt(sel.face.advance(glyph))) * scale;
    }
    return pen;
}

/// Draws a string but stops before any glyph would cross `max_x`, so a long label is cut at its column
/// edge rather than spilling across the screen or into an adjacent element — the renderer's stand-in for
/// the reference's `overflow:hidden`. Returns the x just past the last glyph drawn.
pub fn drawClipped(target: *Framebuffer, x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba, max_x: f32) f32 {
    return drawClippedWeighted(target, x, baseline_y, letters, size_px, colour, max_x, .auto);
}

/// As `drawClipped`, but at a chosen weight — a long semibold label cut at its column edge rather than
/// spilling into an adjacent element.
pub fn drawClippedWeighted(target: *Framebuffer, x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba, max_x: f32, weight: Weight) f32 {
    const sel = selectFace(size_px, weight);
    const px = emSize(size_px);
    const scale = px / @as(f32, @floatFromInt(sel.face.units_per_em));

    var pen = x;
    var view = std.unicode.Utf8View.initUnchecked(letters);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const glyph = sel.face.glyphIndex(cp);
        const advance = @as(f32, @floatFromInt(sel.face.advance(glyph))) * scale;
        if (pen + advance > max_x) break; // the next glyph would cross the edge; stop cleanly
        emit(target, sel, glyph, px, pen, baseline_y, colour);
        pen += advance;
    }
    return pen;
}

/// Draws a string centred horizontally on `centre_x`, baseline at `baseline_y`.
pub fn drawCentred(target: *Framebuffer, centre_x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba) void {
    const width = measure(letters, size_px);
    _ = draw(target, centre_x - width / 2.0, baseline_y, letters, size_px, colour);
}

/// Draws one glyph at the pen, going through the coverage cache. Glyph 0 is the missing-glyph
/// box; drawing it litters the screen with tofu, so a codepoint the subset does not carry is
/// skipped, leaving its advance as a gap.
fn emit(target: *Framebuffer, sel: Selected, glyph: u16, px: f32, pen_x: f32, baseline_y: f32, colour: Rgba) void {
    if (glyph == 0) return;
    if (cachedGlyph(sel.face, sel.id, glyph, px)) |g| blit(target, g, pen_x, baseline_y, colour);
}

/// Blends a glyph's coverage onto the target at pen (x, baseline_y). The pen is snapped to a
/// whole pixel here, which is why a glyph's coverage depends only on its face, index, and em
/// size — never on the fractional pen — and can be cached.
fn blit(target: *Framebuffer, g: Glyph, pen_x: f32, baseline_y: f32, colour: Rgba) void {
    if (g.width == 0 or g.height == 0) return;
    const ox: i32 = @as(i32, @intFromFloat(@round(pen_x))) + g.left;
    const oy: i32 = @as(i32, @intFromFloat(@round(baseline_y))) + g.top;
    var gy: u32 = 0;
    while (gy < g.height) : (gy += 1) {
        const ty = oy + @as(i32, @intCast(gy));
        if (ty < 0 or ty >= @as(i32, @intCast(target.height))) continue;
        var gx: u32 = 0;
        while (gx < g.width) : (gx += 1) {
            const tx = ox + @as(i32, @intCast(gx));
            if (tx < 0 or tx >= @as(i32, @intCast(target.width))) continue;
            const cov = g.coverage[gy * g.width + gx];
            if (cov == 0) continue;
            target.blend(@intCast(tx), @intCast(ty), colour, cov);
        }
    }
}

// --- The glyph-coverage cache ---
//
// The shell repaints the current surface every frame, and almost every frame draws the same
// words at the same sizes. Rasterizing each glyph from its outline every time is pure waste:
// the outline never changes, and `blit` snaps the pen to a whole pixel, so a glyph's coverage
// is a pure function of (face, glyph index, em pixel size). This turns each such glyph to
// pixels once and blits from the cache thereafter, so a warm frame allocates nothing and
// rasterizes nothing.
//
// Memory is fixed and lives in static storage: an open-addressed table of `cache_slots`
// entries over a `cache_arena`-byte coverage pool. A hit is O(1) (hash, then a short linear
// probe). When the table load or the arena would overflow — only if more distinct glyphs are
// live at once than the cache holds, which a UI's small glyph set never reaches in steady
// state — the whole cache empties in one O(1) generational step and re-warms. There is no
// unbounded growth and no per-frame heap.

/// A glyph handed back for blitting: geometry plus a coverage slice into the cache arena.
const Glyph = struct { width: u32, height: u32, left: i32, top: i32, coverage: []const u8 };

const cache_slots: usize = 4096; // power of two, so the hash masks to an index
const cache_load: usize = cache_slots * 3 / 4; // hold the table under a 0.75 load factor
const cache_arena: usize = 3 * 1024 * 1024; // coverage-byte pool the entries carve from

/// One cached glyph. `gen` records the generation it was written in; an entry whose `gen` is
/// not the cache's current generation reads as empty, which is how a generational clear
/// empties the whole table in a single step.
const CacheEntry = struct {
    face_id: u8 = 0,
    glyph: u16 = 0,
    px_bits: u32 = 0,
    gen: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    left: i32 = 0,
    top: i32 = 0,
    coverage: []const u8 = &.{},
};

var cache_entries: [cache_slots]CacheEntry = [_]CacheEntry{.{}} ** cache_slots;
var cache_bytes: [cache_arena]u8 = undefined;
var cache_used: usize = 0; // arena bytes taken this generation
var cache_count: usize = 0; // live entries this generation
var cache_gen: u32 = 1; // current generation; entries default to gen 0, so the table starts empty

fn cacheHash(face_id: u8, glyph: u16, px_bits: u32) usize {
    var h: u64 = 0xcbf29ce484222325;
    h = (h ^ face_id) *% 0x100000001b3;
    h = (h ^ glyph) *% 0x100000001b3;
    h = (h ^ px_bits) *% 0x100000001b3;
    return @intCast(h & (cache_slots - 1));
}

/// Empties the cache in one step: bump the generation so every entry reads stale, and reset
/// the arena. O(1), so a rare overflow costs a re-warm, not a stall.
fn cacheClear() void {
    cache_gen +%= 1;
    if (cache_gen == 0) cache_gen = 1; // 0 is the sentinel every entry starts at
    cache_used = 0;
    cache_count = 0;
}

/// Fetches a glyph's coverage from the cache, rasterizing and inserting it on a miss. Returns
/// null only when the glyph cannot be produced at all (a malformed outline).
fn cachedGlyph(face: truetype.Face, face_id: u8, glyph: u16, px: f32) ?Glyph {
    const px_bits: u32 = @bitCast(px);
    // Probe for this exact (face, glyph, size). The probe stops at the first stale slot, which
    // is also the insertion slot on a miss; the load factor guarantees one always exists.
    var i = cacheHash(face_id, glyph, px_bits);
    while (cache_entries[i].gen == cache_gen) : (i = (i + 1) & (cache_slots - 1)) {
        const e = &cache_entries[i];
        if (e.face_id == face_id and e.glyph == glyph and e.px_bits == px_bits) {
            return .{ .width = e.width, .height = e.height, .left = e.left, .top = e.top, .coverage = e.coverage };
        }
    }

    // Miss: rasterize once into a stack scratch arena, enough for one UI glyph's edges, ring,
    // and coverage, then copy the coverage into the persistent arena. The scratch is stack, so
    // even a miss touches no heap.
    var scratch: [192 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const bmp = truetype.rasterize(face, glyph, px, fba.allocator()) catch return null;

    // If the table load or the arena would overflow, empty the cache and re-probe from the top
    // of an empty table. A single glyph always fits the arena, so this terminates at once.
    if (cache_count >= cache_load or cache_used + bmp.coverage.len > cache_arena) {
        cacheClear();
        i = cacheHash(face_id, glyph, px_bits);
    }

    const stored = cache_bytes[cache_used .. cache_used + bmp.coverage.len];
    @memcpy(stored, bmp.coverage);
    cache_used += bmp.coverage.len;
    cache_entries[i] = .{
        .face_id = face_id,
        .glyph = glyph,
        .px_bits = px_bits,
        .gen = cache_gen,
        .width = bmp.width,
        .height = bmp.height,
        .left = bmp.left,
        .top = bmp.top,
        .coverage = stored,
    };
    cache_count += 1;
    return .{ .width = bmp.width, .height = bmp.height, .left = bmp.left, .top = bmp.top, .coverage = stored };
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

test "the glyph cache hands back coverage identical to a fresh rasterization" {
    const sel = selectFace(22, .auto);
    const px = emSize(22);
    const glyph = sel.face.glyphIndex('a');

    // Straight from the outline: the pixels the old, cache-free path produced every frame.
    var fresh = try truetype.rasterize(sel.face, glyph, px, testing.allocator);
    defer fresh.deinit(testing.allocator);

    // The cached path must reproduce that glyph byte for byte — same geometry, same coverage.
    const cached = cachedGlyph(sel.face, sel.id, glyph, px).?;
    try testing.expectEqual(fresh.width, cached.width);
    try testing.expectEqual(fresh.height, cached.height);
    try testing.expectEqual(fresh.left, cached.left);
    try testing.expectEqual(fresh.top, cached.top);
    try testing.expectEqualSlices(u8, fresh.coverage, cached.coverage);

    // A second fetch is a hit: the very same arena slice, no re-rasterization.
    const again = cachedGlyph(sel.face, sel.id, glyph, px).?;
    try testing.expect(cached.coverage.ptr == again.coverage.ptr);
}

test "a generational clear empties the cache and it re-warms to the same coverage" {
    const sel = selectFace(14, .auto);
    const px = emSize(14);
    const glyph = sel.face.glyphIndex('g');

    const warm = cachedGlyph(sel.face, sel.id, glyph, px).?;
    const snapshot = try testing.allocator.dupe(u8, warm.coverage); // survives the arena being reused
    defer testing.allocator.free(snapshot);

    cacheClear();
    const rewarmed = cachedGlyph(sel.face, sel.id, glyph, px).?;
    try testing.expectEqualSlices(u8, snapshot, rewarmed.coverage);
}

test "a warm redraw adds no cache entries and no arena bytes" {
    var target = try Framebuffer.init(testing.allocator, 320, 60, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();

    _ = draw(&target, 6, 44, "steady state repaint", 15, white); // warm: rasterize each glyph once
    const used_before = cache_used;
    const count_before = cache_count;

    _ = draw(&target, 6, 44, "steady state repaint", 15, white); // the next frame: all hits
    // No new entry and not one more arena byte: the redraw rasterized nothing and allocated nothing,
    // which is exactly what a steady-state frame does on the render path.
    try testing.expectEqual(count_before, cache_count);
    try testing.expectEqual(used_before, cache_used);
}

test "distinct sizes and weights are separate cache entries" {
    const small = selectFace(12, .auto);
    const large = selectFace(24, .auto); // past the semibold threshold: a different face and size
    const g_small = small.face.glyphIndex('e');
    const g_large = large.face.glyphIndex('e');
    const a = cachedGlyph(small.face, small.id, g_small, emSize(12)).?;
    const b = cachedGlyph(large.face, large.id, g_large, emSize(24)).?;
    // Different em sizes yield different bitmaps, held under different keys — never aliased.
    try testing.expect(a.coverage.ptr != b.coverage.ptr);
    try testing.expect(a.width != b.width or a.height != b.height);
}
