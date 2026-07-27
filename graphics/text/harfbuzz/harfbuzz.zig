//! The HarfBuzz shaping adapter: a Zig surface over the compiled HarfBuzz (ADR 0006).
//!
//! HarfBuzz is compiled from the vendored single-file amalgamation and reached only through this
//! adapter. It turns a run of UTF-8 text and a font into positioned glyph ids — the kerning,
//! ligatures, and script handling the layout needs before FreeType rasterises each glyph. A font
//! is loaded from bytes in memory and scaled to a pixel size; a run is shaped into a caller
//! buffer of glyph id + advance + offset, in 26.6 fixed-point pixels. HarfBuzz's C types stay
//! inside this module.
//!
//! Built only where the source is vendored; without it the layout falls back to unshaped
//! advances.

const std = @import("std");
const c = @import("bindings.zig").c;

pub const Error = error{ FontLoadFailed, BufferAllocFailed };

/// One shaped glyph: its id in the font, and its placement relative to the pen, in 26.6
/// fixed-point pixels (divide by 64 for whole pixels).
pub const Glyph = struct {
    id: u32,
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

/// A font loaded for shaping, from bytes in memory. The bytes must outlive the font.
pub const Font = struct {
    blob: *c.hb_blob_t,
    face: *c.hb_face_t,
    font: *c.hb_font_t,

    pub fn load(font_bytes: []const u8, pixel_height: u32) Error!Font {
        const blob = c.hb_blob_create(
            font_bytes.ptr,
            @intCast(font_bytes.len),
            c.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.FontLoadFailed;
        errdefer c.hb_blob_destroy(blob);
        const face = c.hb_face_create(blob, 0) orelse return error.FontLoadFailed;
        errdefer c.hb_face_destroy(face);
        const font = c.hb_font_create(face) orelse return error.FontLoadFailed;

        // Scale so advances come back in 26.6 fixed-point pixels at the requested height.
        const scale: c_int = @intCast(pixel_height * 64);
        c.hb_font_set_scale(font, scale, scale);
        return .{ .blob = blob, .face = face, .font = font };
    }

    pub fn deinit(self: *Font) void {
        c.hb_font_destroy(self.font);
        c.hb_face_destroy(self.face);
        c.hb_blob_destroy(self.blob);
    }

    /// Shapes `text` (UTF-8) into `out`, returning how many glyphs it produced (never more than
    /// `out.len`). Segment properties (script, direction, language) are guessed from the text.
    pub fn shape(self: Font, text: []const u8, out: []Glyph) Error!usize {
        const buffer = c.hb_buffer_create() orelse return error.BufferAllocFailed;
        defer c.hb_buffer_destroy(buffer);
        c.hb_buffer_add_utf8(buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buffer);
        c.hb_shape(self.font, buffer, null, 0);

        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buffer, &count);
        const positions = c.hb_buffer_get_glyph_positions(buffer, &count);
        const n = @min(@as(usize, count), out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = .{
                .id = infos[i].codepoint, // after shaping this is the glyph id, not a code point
                .x_advance = positions[i].x_advance,
                .y_advance = positions[i].y_advance,
                .x_offset = positions[i].x_offset,
                .y_offset = positions[i].y_offset,
            };
        }
        return n;
    }
};

// --- Tests (real shaping against the compiled HarfBuzz) ---

const std_testing = std.testing;
const design = @import("design");

test "the compiled HarfBuzz reports a 14.x version" {
    const v = std.mem.span(c.hb_version_string());
    try std_testing.expect(std.mem.startsWith(u8, v, "14."));
}

test "shaping a Latin run against Sora yields one glyph per character with real advances" {
    var font = try Font.load(design.fonts.sora_regular, 32);
    defer font.deinit();

    var glyphs: [8]Glyph = undefined;
    const n = try font.shape("AV", &glyphs);
    try std_testing.expectEqual(@as(usize, 2), n);
    for (glyphs[0..n]) |g| {
        try std_testing.expect(g.id != 0); // a real glyph, not .notdef
        try std_testing.expect(g.x_advance > 0); // it advances the pen
    }
}
