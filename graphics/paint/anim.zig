//! The animation easing engine: cubic-bezier timing and interpolation for the shell's motion.
//!
//! Motion in the design is not linear — surfaces settle rather than snap, with a gentle spring that
//! overshoots slightly before coming to rest. That feel is a cubic-bezier timing curve, the same one
//! the theme records, and this module evaluates it: given a linear progress from 0 to 1, it returns the
//! eased progress, which the shell uses to drive a transition — a card sliding up, a screen fading in,
//! the agent pulse breathing. Because the spring curve rises above 1 near the end, the eased value can
//! exceed 1, which is exactly the overshoot that reads as a settle. Interpolation is provided alongside
//! so a caller turns an eased progress directly into a position, size, or alpha. Keeping the timing pure
//! means an animation is a deterministic function of its progress: the same frame index always produces
//! the same state, so a transition can be rendered, tested, and replayed without a clock.
//!
//! A real device advances progress from a frame timer; here progress is supplied, so motion is
//! reproducible frame by frame.

const std = @import("std");
const theme = @import("design").theme;

/// Evaluates a cubic-bezier timing curve with control points (x1,y1) and (x2,y2) — endpoints fixed at
/// (0,0) and (1,1) — at a linear `progress` in [0,1]. Returns the eased value, which may exceed 1 when
/// the curve overshoots (a spring settle).
pub fn ease(progress: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const p = std.math.clamp(progress, 0.0, 1.0);
    // Find the curve parameter t whose x equals p, by bisection (x is monotonic for these controls).
    var low: f32 = 0.0;
    var high: f32 = 1.0;
    var t: f32 = p;
    var iter: u8 = 0;
    while (iter < 24) : (iter += 1) {
        t = (low + high) * 0.5;
        const x = bezier(t, x1, x2);
        if (x < p) low = t else high = t;
    }
    return bezier(t, y1, y2);
}

/// One coordinate of a cubic bezier with endpoints 0 and 1 and controls c1, c2.
fn bezier(t: f32, c1: f32, c2: f32) f32 {
    const u = 1.0 - t;
    return 3.0 * u * u * t * c1 + 3.0 * u * t * t * c2 + t * t * t;
}

/// The shell's signature spring easing, from the theme's control points.
pub fn springEase(progress: f32) f32 {
    const scale = 1000.0;
    return ease(
        progress,
        @as(f32, @floatFromInt(theme.ease_spring_x1)) / scale,
        @as(f32, @floatFromInt(theme.ease_spring_y1)) / scale,
        @as(f32, @floatFromInt(theme.ease_spring_x2)) / scale,
        @as(f32, @floatFromInt(theme.ease_spring_y2)) / scale,
    );
}

/// Linear interpolation from a to b by t (t is typically an eased progress).
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Interpolates an alpha in [0,255] by t, clamped, for a fade.
pub fn fade(from: u8, to: u8, t: f32) u8 {
    const value = lerp(@floatFromInt(from), @floatFromInt(to), std.math.clamp(t, 0.0, 1.0));
    return @intFromFloat(std.math.clamp(value, 0.0, 255.0));
}

const testing = std.testing;

test "easing is pinned at the endpoints" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), springEase(0.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), springEase(1.0), 0.001);
}

test "a linear curve returns its input" {
    // Control points on the diagonal make cubic-bezier the identity.
    try testing.expectApproxEqAbs(@as(f32, 0.5), ease(0.5, 1.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.25), ease(0.25, 1.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0), 0.01);
}

test "the spring overshoots above 1 before settling" {
    // Somewhere in the last third the eased value rises above 1 (the settle), then returns to 1.
    var overshot = false;
    var p: f32 = 0.6;
    while (p < 1.0) : (p += 0.02) {
        if (springEase(p) > 1.0) overshot = true;
    }
    try testing.expect(overshot);
}

test "easing is monotonic in progress up to the overshoot region" {
    // Through the first half the curve only rises.
    var previous: f32 = -1.0;
    var p: f32 = 0.0;
    while (p <= 0.5) : (p += 0.05) {
        const value = springEase(p);
        try testing.expect(value >= previous);
        previous = value;
    }
}

test "lerp and fade move from start to end" {
    try testing.expectApproxEqAbs(@as(f32, 15.0), lerp(10.0, 20.0, 0.5), 0.001);
    try testing.expectEqual(@as(u8, 0), fade(0, 255, 0.0));
    try testing.expectEqual(@as(u8, 255), fade(0, 255, 1.0));
    const mid = fade(0, 255, 0.5);
    try testing.expect(mid > 120 and mid < 135);
}
