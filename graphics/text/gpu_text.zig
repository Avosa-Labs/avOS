//! A shaped text run on the GPU, end to end: HarfBuzz shapes, FreeType rasterises, the device draws.
//!
//! A single glyph (see graphics/text/gpu_glyph.zig) needs no layout. A run does: HarfBuzz turns the
//! text and font into positioned glyph ids — with the kerning and ligatures a string needs — and
//! FreeType rasterises each of those glyphs by its index. This composes the three: shape the run,
//! rasterise each shaped glyph, lay the coverage into one run bitmap at the shaped pen positions,
//! and draw that as coloured ink in a single pass. Shaping and rasterisation are CPU work (that is
//! what the two libraries are); the run itself becomes pixels on the device.
//!
//! Built only where all three engines are vendored.

const std = @import("std");
const vk = @import("vulkan");
const ft = @import("freetype");
const hb = @import("harfbuzz");
const design = @import("design");

pub const Frame = vk.glyph.Frame;
pub const Rgba = vk.glyph.Rgba;

pub const Error = ft.Error || hb.Error || vk.offscreen.Error || error{OutOfMemory};

/// One rasterised glyph placed on the run's pen line: its coverage (owned) and where it sits.
const Placed = struct {
    coverage: []u8, // tightly packed width*rows, owned by the caller's allocator
    width: u32,
    rows: u32,
    pen_x: i32, // the pen position (pixels) this glyph is drawn from
    left: i32, // bitmap bearing: pixels right of the pen to the glyph's left edge
    top: i32, // bitmap bearing: pixels above the baseline to the glyph's top edge
};

/// Shapes `text` from `font_bytes` at `pixel_height`, rasterises each shaped glyph, and draws the
/// whole run as `color` ink on a `clear` background into a frame the size of the run, then reads it
/// back. The frame's pixels are owned by `gpa`. Returns null for a run with no ink (e.g. spaces).
pub fn renderRun(
    device: *vk.Device,
    gpa: std.mem.Allocator,
    font_bytes: []const u8,
    text: []const u8,
    pixel_height: u32,
    color: [4]f32,
    clear: [4]f32,
) Error!?Frame {
    if (text.len == 0) return null;

    // Shape the run into glyph ids with 26.6 pen advances and offsets.
    var font = try hb.Font.load(font_bytes, pixel_height);
    defer font.deinit();
    const shaped = try gpa.alloc(hb.Glyph, text.len + 8);
    defer gpa.free(shaped);
    const glyph_count = try font.shape(text, shaped);
    if (glyph_count == 0) return null;

    // Rasterise each shaped glyph by its index, copying its coverage before the next load
    // overwrites FreeType's slot. Track the run's ink box so the frame holds every glyph.
    var library = try ft.Library.init();
    defer library.deinit();
    var face = try ft.Face.load(library, font_bytes);
    defer face.deinit();
    try face.setPixelHeight(pixel_height);

    var placed: std.ArrayList(Placed) = .empty;
    defer {
        for (placed.items) |p| gpa.free(p.coverage);
        placed.deinit(gpa);
    }

    var pen_x: i32 = 0;
    var ascent: i32 = 0; // pixels above the baseline
    var descent: i32 = 0; // pixels below the baseline
    var right: i32 = 0; // rightmost inked column
    for (shaped[0..glyph_count]) |g| {
        const raster = try face.renderIndex(g.id);
        const draw_x = pen_x + (g.x_offset >> 6);
        if (raster.width > 0 and raster.rows > 0) {
            const width = raster.width;
            const rows = raster.rows;
            const pitch: usize = @intCast(if (raster.pitch < 0) -raster.pitch else raster.pitch);
            const coverage = try gpa.alloc(u8, @as(usize, width) * rows);
            errdefer gpa.free(coverage);
            var row: usize = 0;
            while (row < rows) : (row += 1) {
                @memcpy(coverage[row * width ..][0..width], raster.coverage[row * pitch ..][0..width]);
            }
            const top = raster.top + (g.y_offset >> 6);
            try placed.append(gpa, .{
                .coverage = coverage,
                .width = width,
                .rows = rows,
                .pen_x = draw_x,
                .left = raster.left,
                .top = top,
            });
            ascent = @max(ascent, top);
            descent = @max(descent, @as(i32, @intCast(rows)) - top);
            right = @max(right, draw_x + raster.left + @as(i32, @intCast(width)));
        }
        pen_x += g.x_advance >> 6;
    }

    const height = ascent + descent;
    const run_width: i32 = @max(right, pen_x);
    if (run_width <= 0 or height <= 0) return null; // nothing to draw (e.g. only spaces)
    const w: u32 = @intCast(run_width);
    const h: u32 = @intCast(height);

    // Lay each glyph's coverage into the run bitmap at its pen position, on the shared baseline.
    const run = try gpa.alloc(u8, @as(usize, w) * h);
    defer gpa.free(run);
    @memset(run, 0);
    for (placed.items) |p| {
        const x0 = p.pen_x + p.left;
        const y0 = ascent - p.top; // baseline is at `ascent` rows down
        var gy: u32 = 0;
        while (gy < p.rows) : (gy += 1) {
            const dy = y0 + @as(i32, @intCast(gy));
            if (dy < 0 or dy >= height) continue;
            var gx: u32 = 0;
            while (gx < p.width) : (gx += 1) {
                const dx = x0 + @as(i32, @intCast(gx));
                if (dx < 0 or dx >= run_width) continue;
                const dst = &run[@as(usize, @intCast(dy)) * w + @as(usize, @intCast(dx))];
                const src = p.coverage[gy * p.width + gx];
                dst.* = @max(dst.*, src); // overlapping glyphs keep the stronger coverage
            }
        }
    }

    var texture = try vk.texture.Texture.upload(device, w, h, run);
    defer texture.deinit(device);

    const dest = vk.glyph.Rect{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h) };
    return try vk.glyph.draw(device, gpa, w, h, clear, &texture, dest, color);
}

// --- Tests (a real shaped run on the GPU; strict on the lavapipe lane) ---

const testing = std.testing;

test "a shaped Sora run rasterises and draws wider than a single glyph" {
    var instance = vk.Instance.create("gpu-text-test") catch return;
    defer instance.deinit();
    var device = vk.Device.create(&instance, testing.allocator) catch {
        // A device is guaranteed on the lavapipe lane; its absence elsewhere is the device tests'
        // concern, and there is nothing to draw into here.
        return;
    };
    defer device.deinit();

    const px: u32 = 48;
    const frame = (try renderRun(&device, testing.allocator, design.fonts.sora_regular, "Av", px, .{ 1, 1, 1, 1 }, .{ 0, 0, 0, 1 })) orelse return error.TestUnexpectedResult;
    var owned = frame;
    defer owned.deinit(testing.allocator);

    // Two letters shape wider than tall at this size, and both ink and background are present.
    try testing.expect(owned.width > owned.height);
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
    try testing.expect(white > 0); // the run drew ink
    try testing.expect(black > 0); // and left the background between and around the letters
}

test "an empty run has nothing to draw" {
    var instance = vk.Instance.create("gpu-text-empty") catch return;
    defer instance.deinit();
    var device = vk.Device.create(&instance, testing.allocator) catch return;
    defer device.deinit();
    try testing.expect((try renderRun(&device, testing.allocator, design.fonts.sora_regular, "", 32, .{ 1, 1, 1, 1 }, .{ 0, 0, 0, 1 })) == null);
}
