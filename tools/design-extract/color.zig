//! Colour conversion for the design extractor: an sRGB hex string to linear-light RGB
//! and to OKLCH, deterministically.
//!
//! The reference design states colour in sRGB hex, but conformance is judged in
//! linear light (per the pixel-gate spec) and the token layer reasons in OKLCH. So a
//! colour is extracted once into both: the linear-light triple a renderer blends, and
//! the OKLCH triple a token role is authored against. The maths is the standard sRGB
//! transfer function and Ottosson's OKLab matrices — no invention — and every result is
//! rounded to a fixed number of places so the same hex always emits the same bytes.

const std = @import("std");

pub const Linear = struct { r: f64, g: f64, b: f64, a: f64 };
pub const Oklch = struct { l: f64, c: f64, h: f64 };

pub const ParseError = error{BadHex};

/// Parses `#rgb`, `#rrggbb`, or `#rrggbbaa` (with or without the leading '#') into
/// 8-bit channels plus alpha. Case-insensitive.
pub fn parseHex(text: []const u8) ParseError![4]u8 {
    var hex = text;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    switch (hex.len) {
        3 => return .{
            try nibble2(hex[0], hex[0]),
            try nibble2(hex[1], hex[1]),
            try nibble2(hex[2], hex[2]),
            255,
        },
        6 => return .{
            try byteAt(hex, 0),
            try byteAt(hex, 2),
            try byteAt(hex, 4),
            255,
        },
        8 => return .{
            try byteAt(hex, 0),
            try byteAt(hex, 2),
            try byteAt(hex, 4),
            try byteAt(hex, 6),
        },
        else => return ParseError.BadHex,
    }
}

fn nibble(c: u8) ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => ParseError.BadHex,
    };
}

fn nibble2(hi: u8, lo: u8) ParseError!u8 {
    return (try nibble(hi)) * 16 + (try nibble(lo));
}

fn byteAt(hex: []const u8, index: usize) ParseError!u8 {
    return nibble2(hex[index], hex[index + 1]);
}

/// The sRGB electro-optical transfer: an 8-bit channel to linear light in 0..1.
pub fn srgbToLinear(channel: u8) f64 {
    const c = @as(f64, @floatFromInt(channel)) / 255.0;
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

pub fn toLinear(rgba: [4]u8) Linear {
    return .{
        .r = srgbToLinear(rgba[0]),
        .g = srgbToLinear(rgba[1]),
        .b = srgbToLinear(rgba[2]),
        .a = @as(f64, @floatFromInt(rgba[3])) / 255.0,
    };
}

/// Linear-light sRGB to OKLCH (L in 0..1, C ≥ 0, h in degrees 0..360), via OKLab.
pub fn toOklch(linear: Linear) Oklch {
    const l_ = std.math.cbrt(0.4122214708 * linear.r + 0.5363325363 * linear.g + 0.0514459929 * linear.b);
    const m_ = std.math.cbrt(0.2119034982 * linear.r + 0.6806995451 * linear.g + 0.1073969566 * linear.b);
    const s_ = std.math.cbrt(0.0883024619 * linear.r + 0.2817188376 * linear.g + 0.6299787005 * linear.b);

    const ok_l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    const ok_a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    const ok_b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

    var h = std.math.radiansToDegrees(std.math.atan2(ok_b, ok_a));
    if (h < 0) h += 360.0;
    return .{ .l = ok_l, .c = std.math.hypot(ok_a, ok_b), .h = h };
}

/// Rounds to `places` decimals, so serialization is stable across runs and platforms.
pub fn round(value: f64, places: u32) f64 {
    var scale: f64 = 1.0;
    var i: u32 = 0;
    while (i < places) : (i += 1) scale *= 10.0;
    return @round(value * scale) / scale;
}

const testing = std.testing;

test "hex parses in three forms" {
    try testing.expectEqual([4]u8{ 0x9a, 0x6c, 0xff, 255 }, try parseHex("#9a6cff"));
    try testing.expectEqual([4]u8{ 0x4b, 0x3a, 0x66, 0x55 }, try parseHex("4b3a6655"));
    try testing.expectEqual([4]u8{ 0xff, 0xff, 0xff, 255 }, try parseHex("#fff"));
    try testing.expectError(ParseError.BadHex, parseHex("#zz"));
}

test "white and black round-trip through linear and OKLCH" {
    const white = toLinear(try parseHex("#ffffff"));
    try testing.expect(@abs(white.r - 1.0) < 1e-9);
    const okw = toOklch(white);
    try testing.expect(@abs(okw.l - 1.0) < 1e-3); // OKLab L of white ≈ 1
    try testing.expect(okw.c < 1e-3); // white has no chroma

    const black = toLinear(try parseHex("#000000"));
    try testing.expect(black.r == 0.0);
    try testing.expect(toOklch(black).l < 1e-6);
}

test "the agent purple has a sensible hue and chroma" {
    const ok = toOklch(toLinear(try parseHex("#9a6cff")));
    try testing.expect(ok.c > 0.1); // saturated
    try testing.expect(ok.h > 250.0 and ok.h < 320.0); // purple/violet arc
}

test "rounding is stable" {
    try testing.expectEqual(@as(f64, 0.1235), round(0.12345678, 4));
}
