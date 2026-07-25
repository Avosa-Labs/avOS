//! Colour in linear light: the transfer functions between the sRGB values a display
//! stores and the linear-light values arithmetic must happen in, so blends and
//! gradients are physically right rather than the muddy approximation of blending
//! encoded values directly.
//!
//! A colour stored for a display is not proportional to light — it is encoded through
//! a transfer function so that the limited bits are spent where the eye is sensitive.
//! That encoding is why blending two sRGB values by averaging their stored numbers is
//! wrong: halfway between encoded black and encoded white is not half the light, so a
//! gradient blended that way is too dark in its middle and a cross-fade passes through
//! a muddy dip. The fix is not subtle to state — decode to linear light, do the
//! arithmetic there where a value *is* proportional to light, then encode back — and it
//! is visible everywhere gradients and transparency appear. This module is those two
//! transfers and the linear-space operations that sit between them, so the rest of the
//! pipeline can blend and interpolate in the space where the maths is true.
//!
//! This module renders nothing. It converts a channel between encoded and linear light
//! and combines linear channels, as pure functions with pinned endpoints.

const std = @import("std");

/// A linear-light channel: proportional to the light a display emits, in [0, 1].
pub const Linear = f32;
/// An encoded (sRGB) channel as a unit fraction, in [0, 1] — a stored byte over 255.
pub const Encoded = f32;

/// Decodes an sRGB-encoded channel to linear light. The standard sRGB electro-optical
/// transfer function: a short linear segment near black, a gamma curve above it.
pub fn toLinear(encoded: Encoded) Linear {
    const value = std.math.clamp(encoded, 0, 1);
    if (value <= 0.04045) return value / 12.92;
    return std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

/// Encodes a linear-light channel back to sRGB, the inverse of `toLinear`. The pair
/// round-trips: encoding a decoded value returns it within floating-point tolerance.
pub fn toEncoded(linear: Linear) Encoded {
    const value = std.math.clamp(linear, 0, 1);
    if (value <= 0.003_130_8) return value * 12.92;
    return 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
}

/// Converts an encoded byte (0–255) to linear light.
pub fn byteToLinear(byte: u8) Linear {
    return toLinear(@as(f32, @floatFromInt(byte)) / 255.0);
}

/// Converts a linear-light channel to an encoded byte, rounded to the nearest value.
pub fn linearToByte(linear: Linear) u8 {
    const encoded = toEncoded(linear) * 255.0;
    return @intFromFloat(std.math.clamp(@round(encoded), 0, 255));
}

/// Interpolates two encoded channels correctly: decode both to linear, mix there,
/// encode back. This is the operation a gradient must use; mixing the encoded values
/// directly is the muddy-middle bug. The fraction is clamped, since a channel has no
/// meaning outside its range.
pub fn mixEncoded(from: Encoded, to: Encoded, fraction: f32) Encoded {
    const f = std.math.clamp(fraction, 0, 1);
    const linear = toLinear(from) * (1 - f) + toLinear(to) * f;
    return toEncoded(linear);
}

/// Composites a source channel over a destination channel in linear light, given the
/// source's coverage (alpha). The over operator, done where light is additive:
/// `result = src·a + dst·(1−a)`. Returned in linear light for further compositing.
pub fn over(source_linear: Linear, dest_linear: Linear, alpha: f32) Linear {
    const a = std.math.clamp(alpha, 0, 1);
    return source_linear * a + dest_linear * (1 - a);
}

// --- Tests ---

const testing = std.testing;

test "the transfer functions round-trip" {
    var byte: u16 = 0;
    while (byte <= 255) : (byte += 17) {
        const encoded = @as(f32, @floatFromInt(byte)) / 255.0;
        const back = toEncoded(toLinear(encoded));
        try testing.expectApproxEqAbs(encoded, back, 1e-4);
    }
}

test "the transfer functions are pinned at black and white" {
    try testing.expectEqual(@as(Linear, 0), toLinear(0));
    try testing.expectApproxEqAbs(@as(Linear, 1), toLinear(1), 1e-6);
    try testing.expectEqual(@as(Encoded, 0), toEncoded(0));
    try testing.expectApproxEqAbs(@as(Encoded, 1), toEncoded(1), 1e-6);
}

test "a byte round-trips through linear within one level" {
    var byte: u16 = 0;
    while (byte <= 255) : (byte += 1) {
        const b: u8 = @intCast(byte);
        try testing.expectEqual(b, linearToByte(byteToLinear(b)));
    }
}

test "mixing in linear light is brighter in the middle than mixing encoded values" {
    // The whole point: the linear-correct midpoint of black and white sits well above
    // the naive encoded midpoint (0.5), because half the light is much lighter than
    // half the encoded value.
    const linear_mid = mixEncoded(0.0, 1.0, 0.5);
    try testing.expect(linear_mid > 0.5);
    // A perceptual midpoint of black and white is around 0.5 encoded light -> ~188/255.
    try testing.expect(linear_mid > 0.72 and linear_mid < 0.76);
}

test "mixing is pinned at its endpoints" {
    try testing.expectApproxEqAbs(@as(f32, 0.2), mixEncoded(0.2, 0.8, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), mixEncoded(0.2, 0.8, 1), 1e-6);
}

test "compositing over is additive in light and pinned by alpha" {
    // Full coverage shows only the source; zero coverage shows only the destination.
    try testing.expectApproxEqAbs(@as(Linear, 0.9), over(0.9, 0.1, 1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(Linear, 0.1), over(0.9, 0.1, 0.0), 1e-6);
    // Half coverage is the linear average.
    try testing.expectApproxEqAbs(@as(Linear, 0.5), over(0.9, 0.1, 0.5), 1e-6);
}

test "decoding is monotonic — a larger encoded value is never less light, swept" {
    // The transfer function must not fold, or ordering of brightness would break.
    var previous: Linear = -1;
    var byte: u16 = 0;
    while (byte <= 255) : (byte += 1) {
        const linear = byteToLinear(@intCast(byte));
        try testing.expect(linear >= previous);
        previous = linear;
    }
}
