//! Keeping colour values inside the range the display can show, so a computed colour
//! is clamped into gamut rather than wrapping into a wrong one.
//!
//! Colour arithmetic overshoots. Add two bright values, apply a filter, and a channel
//! lands above the maximum the display can represent or below zero; what happens next
//! decides whether the picture is right. Wrapping — letting an over-range value roll
//! over — turns a slightly-too-bright white into a dark colour, the single ugliest
//! failure in rendering, because it inverts exactly the pixels that were meant to be
//! brightest. Clamping instead holds an out-of-range channel at the nearest value the
//! display can show, so an overshoot reads as the brightest white rather than garbage.
//! Alpha is the same story with a stricter rule: a premultiplied colour must never have
//! a channel exceeding its alpha, or compositing it produces impossible colours. So
//! colour values are clamped to their valid range and premultiplication is checked, and
//! the picture stays inside what the display can honestly show.
//!
//! This module draws no pixel. It clamps channels into range, classifies whether a
//! colour is in gamut, and checks premultiplied validity, as pure functions over the
//! channel values.

const std = @import("std");

/// A colour channel value in the normalized range where 0 is none and 1 is full. Values
/// are computed in floating point and may overshoot before clamping.
pub const Channel = f32;

/// The minimum and maximum a channel may hold once clamped.
pub const channel_min: Channel = 0.0;
pub const channel_max: Channel = 1.0;

/// Clamps a channel into the valid range. An over-range value is held at the maximum and
/// an under-range value at the minimum, so an overshoot reads as full intensity rather
/// than wrapping into a wrong colour. A NaN clamps to the minimum, since it is not a
/// value the display can show.
pub fn clampChannel(value: Channel) Channel {
    if (std.math.isNan(value)) return channel_min;
    return std.math.clamp(value, channel_min, channel_max);
}

/// Whether a channel is already within the displayable range.
pub fn inGamut(value: Channel) bool {
    return value >= channel_min and value <= channel_max;
}

/// A colour with straight (non-premultiplied) alpha.
pub const Color = struct {
    r: Channel,
    g: Channel,
    b: Channel,
    a: Channel,

    /// Clamps every channel into range.
    pub fn clamped(color: Color) Color {
        return .{
            .r = clampChannel(color.r),
            .g = clampChannel(color.g),
            .b = clampChannel(color.b),
            .a = clampChannel(color.a),
        };
    }

    /// Whether every channel is in gamut.
    pub fn allInGamut(color: Color) bool {
        return inGamut(color.r) and inGamut(color.g) and inGamut(color.b) and inGamut(color.a);
    }
};

/// Whether a premultiplied colour is valid: each colour channel must not exceed its
/// alpha, because a premultiplied channel represents colour already scaled by alpha and
/// a channel above alpha is a colour that cannot exist.
pub fn premultipliedValid(r: Channel, g: Channel, b: Channel, a: Channel) bool {
    return r <= a and g <= a and b <= a and r >= 0 and g >= 0 and b >= 0 and a >= 0;
}

test "an in-range channel is unchanged" {
    try std.testing.expectEqual(@as(Channel, 0.5), clampChannel(0.5));
    try std.testing.expectEqual(channel_min, clampChannel(0.0));
    try std.testing.expectEqual(channel_max, clampChannel(1.0));
}

test "an overshoot clamps to the maximum, not wrapping" {
    try std.testing.expectEqual(channel_max, clampChannel(1.5));
    try std.testing.expectEqual(channel_max, clampChannel(1000.0));
}

test "an undershoot clamps to the minimum" {
    try std.testing.expectEqual(channel_min, clampChannel(-0.3));
}

test "NaN clamps to the minimum" {
    try std.testing.expectEqual(channel_min, clampChannel(std.math.nan(f32)));
}

test "gamut membership is the closed unit range" {
    try std.testing.expect(inGamut(0.0));
    try std.testing.expect(inGamut(1.0));
    try std.testing.expect(!inGamut(1.1));
    try std.testing.expect(!inGamut(-0.1));
}

test "a clamped colour is always in gamut" {
    const overshoot: Color = .{ .r = 2.0, .g = -1.0, .b = 0.5, .a = 1.5 };
    try std.testing.expect(overshoot.clamped().allInGamut());
}

test "premultiplied validity forbids a channel above alpha" {
    try std.testing.expect(premultipliedValid(0.3, 0.3, 0.3, 0.5));
    try std.testing.expect(premultipliedValid(0.5, 0.5, 0.5, 0.5)); // equal is valid
    try std.testing.expect(!premultipliedValid(0.8, 0.3, 0.3, 0.5)); // r exceeds alpha
}

test "clamping is idempotent and always lands in gamut, swept" {
    // The no-wrap property: whatever the input, one clamp lands in gamut and a second
    // clamp changes nothing.
    const inputs = [_]Channel{ -2.0, -0.1, 0.0, 0.5, 1.0, 1.1, 100.0 };
    for (inputs) |value| {
        const once = clampChannel(value);
        try std.testing.expect(inGamut(once));
        try std.testing.expectEqual(once, clampChannel(once));
    }
}
