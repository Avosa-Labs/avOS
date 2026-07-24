//! An RGBA framebuffer and a self-contained PNG encoder, the surface the render pipeline draws onto.
//!
//! This is where the platform stops deciding what to draw and starts producing pixels. A framebuffer is
//! a width-by-height grid of straight-alpha RGBA samples; the pipeline composites onto it with
//! source-over blending, and the result is encoded to a PNG so a frame is a real, viewable artifact
//! rather than a description of one. The encoder carries its own DEFLATE (stored blocks), Adler-32, and
//! CRC-32 so it depends on nothing outside the standard library — a frame can be produced on any host
//! the compiler runs on, deterministically, with no image library. The whole module is bounded and
//! allocation-explicit: the buffer is one contiguous allocation, blending is a fixed cost per covered
//! pixel, and encoding is linear in the pixel count. Keeping the surface simple and the encoder
//! dependency-free is what lets the higher layers render into something they can actually show.
//!
//! Colours are straight (non-premultiplied) alpha in sRGB, matching the design tokens' `Colour`.

const std = @import("std");

/// A straight-alpha sRGB sample.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// A width-by-height grid of RGBA samples in row-major order.
pub const Framebuffer = struct {
    width: u32,
    height: u32,
    /// Row-major RGBA, four bytes per pixel, length width*height*4.
    pixels: []u8,
    allocator: std.mem.Allocator,

    /// Allocates a framebuffer of the given size, cleared to the fill colour.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, fill: Rgba) !Framebuffer {
        const count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(u8, count * 4);
        const buffer: Framebuffer = .{ .width = width, .height = height, .pixels = pixels, .allocator = allocator };
        var index: usize = 0;
        while (index < pixels.len) : (index += 4) {
            pixels[index + 0] = fill.r;
            pixels[index + 1] = fill.g;
            pixels[index + 2] = fill.b;
            pixels[index + 3] = fill.a;
        }
        return buffer;
    }

    pub fn deinit(buffer: *Framebuffer) void {
        buffer.allocator.free(buffer.pixels);
    }

    inline fn offset(buffer: Framebuffer, x: u32, y: u32) usize {
        return (@as(usize, y) * @as(usize, buffer.width) + @as(usize, x)) * 4;
    }

    /// Reads a pixel. Out-of-bounds reads return transparent black rather than trapping, so callers may
    /// sample freely at edges.
    pub fn get(buffer: Framebuffer, x: u32, y: u32) Rgba {
        if (x >= buffer.width or y >= buffer.height) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const at = buffer.offset(x, y);
        return .{ .r = buffer.pixels[at], .g = buffer.pixels[at + 1], .b = buffer.pixels[at + 2], .a = buffer.pixels[at + 3] };
    }

    /// Writes a pixel, replacing whatever was there. Out-of-bounds writes are dropped.
    pub fn set(buffer: *Framebuffer, x: u32, y: u32, colour: Rgba) void {
        if (x >= buffer.width or y >= buffer.height) return;
        const at = buffer.offset(x, y);
        buffer.pixels[at + 0] = colour.r;
        buffer.pixels[at + 1] = colour.g;
        buffer.pixels[at + 2] = colour.b;
        buffer.pixels[at + 3] = colour.a;
    }

    /// Composites a source colour over the existing pixel with source-over alpha, at a coverage in
    /// [0,255] (for antialiased edges). Coverage scales the source alpha.
    pub fn blend(buffer: *Framebuffer, x: u32, y: u32, source: Rgba, coverage: u8) void {
        if (x >= buffer.width or y >= buffer.height) return;
        const src_a = @as(u32, source.a) * @as(u32, coverage) / 255;
        if (src_a == 0) return;
        const at = buffer.offset(x, y);
        const dst_r = buffer.pixels[at + 0];
        const dst_g = buffer.pixels[at + 1];
        const dst_b = buffer.pixels[at + 2];
        const dst_a = buffer.pixels[at + 3];
        // out = src*a + dst*(1-a), alpha compositing on straight-alpha with an opaque-leaning result.
        const inv = 255 - src_a;
        buffer.pixels[at + 0] = @intCast((@as(u32, source.r) * src_a + @as(u32, dst_r) * inv + 127) / 255);
        buffer.pixels[at + 1] = @intCast((@as(u32, source.g) * src_a + @as(u32, dst_g) * inv + 127) / 255);
        buffer.pixels[at + 2] = @intCast((@as(u32, source.b) * src_a + @as(u32, dst_b) * inv + 127) / 255);
        buffer.pixels[at + 3] = @intCast(src_a + @as(u32, dst_a) * inv / 255);
    }

    /// Encodes the framebuffer to a PNG byte stream. The caller owns the returned slice.
    pub fn encodePng(buffer: Framebuffer, allocator: std.mem.Allocator) ![]u8 {
        return encode(allocator, buffer.width, buffer.height, buffer.pixels);
    }
};

// --- PNG encoding (self-contained) ---

const png_signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| {
        crc ^= byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask = ~(crc & 1) +% 1; // 0xffffffff if low bit set, else 0
            crc = (crc >> 1) ^ (0xedb88320 & mask);
        }
    }
    return ~crc;
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeBigEndian(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try list.append(allocator, @intCast((value >> 24) & 0xff));
    try list.append(allocator, @intCast((value >> 16) & 0xff));
    try list.append(allocator, @intCast((value >> 8) & 0xff));
    try list.append(allocator, @intCast(value & 0xff));
}

fn writeChunk(list: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: [4]u8, data: []const u8) !void {
    try writeBigEndian(list, allocator, @intCast(data.len));
    const start = list.items.len;
    try list.appendSlice(allocator, &kind);
    try list.appendSlice(allocator, data);
    const crc = crc32(list.items[start..]);
    try writeBigEndian(list, allocator, crc);
}

/// Wraps filtered image data in a minimal zlib stream using only stored (uncompressed) DEFLATE blocks.
fn zlibStore(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 0x78); // CMF: 32K window, deflate
    try out.append(allocator, 0x01); // FLG: no dict, fastest
    var offset: usize = 0;
    while (offset < raw.len or offset == 0) {
        const remaining = raw.len - offset;
        const block_len: usize = @min(remaining, 0xffff);
        const is_last: u8 = if (offset + block_len >= raw.len) 1 else 0;
        try out.append(allocator, is_last); // BFINAL in bit 0, BTYPE 00
        const len: u16 = @intCast(block_len);
        try out.append(allocator, @intCast(len & 0xff));
        try out.append(allocator, @intCast((len >> 8) & 0xff));
        const nlen = ~len;
        try out.append(allocator, @intCast(nlen & 0xff));
        try out.append(allocator, @intCast((nlen >> 8) & 0xff));
        try out.appendSlice(allocator, raw[offset .. offset + block_len]);
        offset += block_len;
        if (block_len == 0) break;
    }
    const adler = adler32(raw);
    try out.append(allocator, @intCast((adler >> 24) & 0xff));
    try out.append(allocator, @intCast((adler >> 16) & 0xff));
    try out.append(allocator, @intCast((adler >> 8) & 0xff));
    try out.append(allocator, @intCast(adler & 0xff));
    return out.toOwnedSlice(allocator);
}

/// Encodes RGBA pixel data (row-major, 4 bytes per pixel) to a PNG.
pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    // Build filtered raw data: each scanline prefixed with filter byte 0 (none).
    const stride = @as(usize, width) * 4;
    var raw = try allocator.alloc(u8, (stride + 1) * @as(usize, height));
    defer allocator.free(raw);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const dst = row * (stride + 1);
        raw[dst] = 0; // filter: none
        const src = @as(usize, row) * stride;
        @memcpy(raw[dst + 1 .. dst + 1 + stride], pixels[src .. src + stride]);
    }

    const idat = try zlibStore(allocator, raw);
    defer allocator.free(idat);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &png_signature);

    var ihdr: [13]u8 = undefined;
    ihdr[0] = @intCast((width >> 24) & 0xff);
    ihdr[1] = @intCast((width >> 16) & 0xff);
    ihdr[2] = @intCast((width >> 8) & 0xff);
    ihdr[3] = @intCast(width & 0xff);
    ihdr[4] = @intCast((height >> 24) & 0xff);
    ihdr[5] = @intCast((height >> 16) & 0xff);
    ihdr[6] = @intCast((height >> 8) & 0xff);
    ihdr[7] = @intCast(height & 0xff);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type: RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(&out, allocator, "IHDR".*, &ihdr);
    try writeChunk(&out, allocator, "IDAT".*, idat);
    try writeChunk(&out, allocator, "IEND".*, &.{});
    return out.toOwnedSlice(allocator);
}

test "a cleared framebuffer holds its fill colour" {
    var fb = try Framebuffer.init(std.testing.allocator, 4, 3, .{ .r = 10, .g = 20, .b = 30, .a = 255 });
    defer fb.deinit();
    try std.testing.expectEqual(Rgba{ .r = 10, .g = 20, .b = 30, .a = 255 }, fb.get(0, 0));
    try std.testing.expectEqual(Rgba{ .r = 10, .g = 20, .b = 30, .a = 255 }, fb.get(3, 2));
}

test "set replaces a pixel; out of bounds is dropped" {
    var fb = try Framebuffer.init(std.testing.allocator, 2, 2, .{ .r = 0, .g = 0, .b = 0 });
    defer fb.deinit();
    fb.set(1, 1, .{ .r = 255, .g = 128, .b = 64, .a = 255 });
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 128, .b = 64, .a = 255 }, fb.get(1, 1));
    fb.set(9, 9, .{ .r = 1, .g = 1, .b = 1 }); // no trap
}

test "full-coverage opaque blend replaces; zero coverage is a no-op" {
    var fb = try Framebuffer.init(std.testing.allocator, 1, 1, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer fb.deinit();
    fb.blend(0, 0, .{ .r = 200, .g = 100, .b = 50, .a = 255 }, 255);
    try std.testing.expectEqual(@as(u8, 200), fb.get(0, 0).r);
    fb.blend(0, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, 0);
    try std.testing.expectEqual(@as(u8, 200), fb.get(0, 0).r); // unchanged
}

test "half-coverage blend is a midpoint" {
    var fb = try Framebuffer.init(std.testing.allocator, 1, 1, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer fb.deinit();
    fb.blend(0, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, 128);
    const mid = fb.get(0, 0).r;
    try std.testing.expect(mid >= 126 and mid <= 130);
}

test "crc32 and adler32 match known vectors" {
    // CRC-32 of "IEND" is a fixed value used in every PNG.
    try std.testing.expectEqual(@as(u32, 0xae426082), crc32("IEND"));
    // Adler-32 of "abc" is 0x024d0127.
    try std.testing.expectEqual(@as(u32, 0x024d0127), adler32("abc"));
}

test "encoded PNG has the signature, an IHDR, and ends with IEND" {
    var fb = try Framebuffer.init(std.testing.allocator, 3, 2, .{ .r = 5, .g = 6, .b = 7, .a = 255 });
    defer fb.deinit();
    const png = try fb.encodePng(std.testing.allocator);
    defer std.testing.allocator.free(png);
    try std.testing.expect(png.len > 8 + 25);
    try std.testing.expectEqualSlices(u8, &png_signature, png[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try std.testing.expectEqualSlices(u8, "IEND", png[png.len - 8 .. png.len - 4]);
}

test "the encoded stream is deterministic" {
    var a = try Framebuffer.init(std.testing.allocator, 8, 8, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    defer a.deinit();
    var b = try Framebuffer.init(std.testing.allocator, 8, 8, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    defer b.deinit();
    const pa = try a.encodePng(std.testing.allocator);
    defer std.testing.allocator.free(pa);
    const pb = try b.encodePng(std.testing.allocator);
    defer std.testing.allocator.free(pb);
    try std.testing.expectEqualSlices(u8, pa, pb);
}
