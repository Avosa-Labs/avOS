//! The FreeType glyph-rasterizer adapter: a Zig surface over the compiled FreeType (ADR 0005).
//!
//! FreeType is compiled from the vendored, digest-verified source and reached only through
//! this adapter. It gives the text path what the pure-Zig rasterizer cannot: TrueType and CFF
//! outlines, the autohinter and the byte-code interpreter, and correct anti-aliased coverage.
//! A face is loaded from font bytes in memory, sized in pixels, and asked for a glyph, which
//! comes back as an 8-bit coverage bitmap and its placement — the same shape the software
//! compositor blends. FreeType's C types stay inside this module; the layout above sees only
//! `Library`, `Face`, and `Glyph`.
//!
//! Built only where the source is vendored (`zig build vendor-engines`); without it the shell
//! falls back to the pure-Zig rasterizer.

const std = @import("std");
const c = @import("bindings.zig").c;

pub const Error = error{ InitFailed, LoadFaceFailed, SetSizeFailed, LoadGlyphFailed };

/// A FreeType library instance. One is enough for a process; a face is loaded against it.
pub const Library = struct {
    handle: c.FT_Library,

    pub fn init() Error!Library {
        var handle: c.FT_Library = null;
        if (c.FT_Init_FreeType(&handle) != 0) return error.InitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(library: *Library) void {
        _ = c.FT_Done_FreeType(library.handle);
    }

    /// The compiled FreeType version, as major, minor, patch.
    pub fn version(library: Library) [3]i32 {
        var major: c.FT_Int = 0;
        var minor: c.FT_Int = 0;
        var patch: c.FT_Int = 0;
        c.FT_Library_Version(library.handle, &major, &minor, &patch);
        return .{ @intCast(major), @intCast(minor), @intCast(patch) };
    }
};

/// A rendered glyph: an 8-bit coverage bitmap and where it sits relative to the pen. The
/// coverage points into the face's glyph slot and stays valid only until the next glyph is
/// rendered on that face — copy it to keep it.
pub const Glyph = struct {
    width: u32,
    rows: u32,
    /// Bytes per bitmap row; negative when FreeType lays the rows out bottom-up.
    pitch: i32,
    /// The bitmap's left edge relative to the pen origin.
    left: i32,
    /// The bitmap's top edge relative to the baseline (positive is up).
    top: i32,
    /// How far to advance the pen after this glyph, in pixels.
    advance: i32,
    coverage: []const u8,
};

/// A font face loaded from bytes in memory. The bytes must outlive the face.
pub const Face = struct {
    handle: c.FT_Face,

    pub fn load(library: Library, font_bytes: []const u8) Error!Face {
        var handle: c.FT_Face = null;
        if (c.FT_New_Memory_Face(library.handle, font_bytes.ptr, @intCast(font_bytes.len), 0, &handle) != 0) {
            return error.LoadFaceFailed;
        }
        return .{ .handle = handle };
    }

    pub fn deinit(face: *Face) void {
        _ = c.FT_Done_Face(face.handle);
    }

    /// Sets the pixel height glyphs are rasterized at.
    pub fn setPixelHeight(face: Face, pixels: u32) Error!void {
        if (c.FT_Set_Pixel_Sizes(face.handle, 0, pixels) != 0) return error.SetSizeFailed;
    }

    /// Loads and rasterizes the glyph for a Unicode code point at the current pixel size — the
    /// simple path when the text is a lone character and shaping is not involved.
    pub fn render(face: Face, codepoint: u21) Error!Glyph {
        if (c.FT_Load_Char(face.handle, codepoint, c.FT_LOAD_RENDER) != 0) return error.LoadGlyphFailed;
        return face.slotGlyph();
    }

    /// Loads and rasterizes a glyph by its index in the font, at the current pixel size. This is
    /// the path shaping takes: HarfBuzz returns glyph indices, not code points.
    pub fn renderIndex(face: Face, glyph_index: u32) Error!Glyph {
        if (c.FT_Load_Glyph(face.handle, @intCast(glyph_index), c.FT_LOAD_RENDER) != 0) return error.LoadGlyphFailed;
        return face.slotGlyph();
    }

    /// Reads the current glyph slot's bitmap and metrics into a Glyph.
    fn slotGlyph(face: Face) Glyph {
        const slot = face.handle.*.glyph;
        const bitmap = slot.*.bitmap;
        const row_bytes: u32 = if (bitmap.pitch < 0) @intCast(-bitmap.pitch) else @intCast(bitmap.pitch);
        const length: usize = @as(usize, bitmap.rows) * row_bytes;
        const coverage: []const u8 = if (bitmap.buffer != null and length > 0) bitmap.buffer[0..length] else &.{};
        return .{
            .width = bitmap.width,
            .rows = bitmap.rows,
            .pitch = bitmap.pitch,
            .left = slot.*.bitmap_left,
            .top = slot.*.bitmap_top,
            .advance = @intCast(slot.*.advance.x >> 6), // 26.6 fixed point to whole pixels
            .coverage = coverage,
        };
    }
};

// --- Tests (compiled FreeType, no GPU) ---

const testing = std.testing;
const design = @import("design");

test "the compiled FreeType initializes and reports a 2.x version" {
    var library = try Library.init();
    defer library.deinit();
    const v = library.version();
    try testing.expectEqual(@as(i32, 2), v[0]);
}

test "a real Sora glyph rasterizes to non-empty, inked coverage" {
    var library = try Library.init();
    defer library.deinit();
    var face = try Face.load(library, design.fonts.sora_regular);
    defer face.deinit();
    try face.setPixelHeight(32);

    const glyph = try face.render('A');
    try testing.expect(glyph.width > 0 and glyph.rows > 0);
    try testing.expect(glyph.advance > 0);
    try testing.expectEqual(glyph.width * glyph.rows, @as(u32, @intCast(glyph.coverage.len)));

    var inked = false;
    for (glyph.coverage) |cov| {
        if (cov != 0) {
            inked = true;
            break;
        }
    }
    try testing.expect(inked); // 'A' has ink
}

test "a space advances the pen but carries no bitmap" {
    var library = try Library.init();
    defer library.deinit();
    var face = try Face.load(library, design.fonts.sora_regular);
    defer face.deinit();
    try face.setPixelHeight(32);

    const glyph = try face.render(' ');
    try testing.expect(glyph.advance > 0); // a space still advances
    try testing.expectEqual(@as(usize, 0), glyph.coverage.len);
}
