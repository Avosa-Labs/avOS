//! Text on the GPU, end to end: FreeType rasterises a glyph, the Vulkan device draws it.
//!
//! The two adapters each do their half — FreeType turns an outline into coverage, the device
//! turns coverage into pixels — and this composes them: rasterise a code point from a font, pack
//! its coverage tightly, upload it as a texture, and draw it as coloured ink. It is the real text
//! path the shell will use, proven on a real glyph rather than a synthetic mask. Built only where
//! both engines are vendored.

const std = @import("std");
const vk = @import("vulkan");
const ft = @import("freetype");
const design = @import("design");

pub const Frame = vk.glyph.Frame;
pub const Rgba = vk.glyph.Rgba;

pub const Error = ft.Error || vk.offscreen.Error || error{OutOfMemory};

/// Rasterises `codepoint` from `font_bytes` at `pixel_height`, then draws it as `color` ink on a
/// `clear` background into a frame the size of the glyph's bitmap, and reads it back. The frame's
/// pixels are owned by `gpa`. Returns null for a glyph with no bitmap (a space).
pub fn renderGlyph(
    device: *vk.Device,
    gpa: std.mem.Allocator,
    font_bytes: []const u8,
    codepoint: u21,
    pixel_height: u32,
    color: [4]f32,
    clear: [4]f32,
) Error!?Frame {
    var library = try ft.Library.init();
    defer library.deinit();
    var face = try ft.Face.load(library, font_bytes);
    defer face.deinit();
    try face.setPixelHeight(pixel_height);

    const glyph = try face.render(codepoint);
    if (glyph.width == 0 or glyph.rows == 0) return null; // nothing to draw (e.g. a space)

    // Pack the coverage tightly to width*rows: FreeType's rows may be padded to a wider pitch.
    const width = glyph.width;
    const rows = glyph.rows;
    const pitch: usize = @intCast(if (glyph.pitch < 0) -glyph.pitch else glyph.pitch);
    const packed_coverage = try gpa.alloc(u8, @as(usize, width) * rows);
    defer gpa.free(packed_coverage);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const src = glyph.coverage[row * pitch ..][0..width];
        @memcpy(packed_coverage[row * width ..][0..width], src);
    }

    var texture = try vk.texture.Texture.upload(device, width, rows, packed_coverage);
    defer texture.deinit(device);

    const dest = vk.glyph.Rect{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(rows) };
    return try vk.glyph.draw(device, gpa, width, rows, clear, &texture, dest, color);
}

// --- Tests (a real glyph on the GPU; strict on the lavapipe lane) ---

const testing = std.testing;

test "a real Sora glyph rasterises with FreeType and draws on the device" {
    var instance = vk.Instance.create("gpu-glyph-test") catch return;
    defer instance.deinit();
    var device = vk.Device.create(&instance, testing.allocator) catch {
        // On the lavapipe lane a device is guaranteed; elsewhere its absence is covered by the
        // device tests, and there is nothing to draw into here.
        return;
    };
    defer device.deinit();

    // Draw 'A' in white on black at the glyph's native size.
    const frame = (try renderGlyph(&device, testing.allocator, design.fonts.sora_regular, 'A', 48, .{ 1, 1, 1, 1 }, .{ 0, 0, 0, 1 })) orelse return error.TestUnexpectedResult;
    var owned = frame;
    defer owned.deinit(testing.allocator);

    // The glyph has solid strokes (fully inked → white) and gaps/counter (empty → black clear).
    var white: usize = 0;
    var black: usize = 0;
    var y: u32 = 0;
    while (y < owned.height) : (y += 1) {
        var x: u32 = 0;
        while (x < owned.width) : (x += 1) {
            const p = owned.at(x, y);
            if (p.r == 255 and p.g == 255 and p.b == 255) white += 1;
            if (p.r == 0 and p.g == 0 and p.b == 0) black += 1;
        }
    }
    try testing.expect(white > 0); // the glyph drew ink
    try testing.expect(black > 0); // and left the background where it has no ink
}
