//! Turning an animation's progress into the value it drives: a cubic-bezier timing
//! curve — including the shell's signature overshooting spring — and interpolation of
//! the scalars, colours, and rectangles a frame is built from.
//!
//! The animation module answers "how far along is this animation" as a fraction; this
//! answers the next two questions a frame actually needs. First, how that fraction is
//! shaped: the design's motion is a cubic-bezier curve, and its signature spring
//! overshoots — settling past its target and easing back — so the curve must be
//! evaluated honestly, overshoot and all, rather than approximated by a monotone
//! ease that would rob the motion of the settle that makes it feel physical. A timing
//! bezier is not a function of the parameter directly: the horizontal axis is progress
//! and the vertical is the eased value, so evaluating it means first solving for the
//! parameter at a given progress, then reading the value there. Second, what that
//! eased fraction drives: a position between two points, a colour between two colours,
//! a size between two sizes — the linear interpolations every animated property comes
//! down to, each careful with rounding and with the overshoot a spring can produce.
//!
//! This module computes values; it animates nothing and draws nothing. It is pure
//! arithmetic over a curve and its endpoints.

const std = @import("std");
const design = @import("design");
const tree = @import("../scene/tree.zig");

const theme = design.theme;
pub const Colour = theme.Colour;
pub const Transform = tree.Transform;

/// Evaluates a cubic Bézier component with endpoints pinned at 0 and 1 and the two
/// control values `c1` and `c2`, at parameter `t`. This is one axis of the curve;
/// the timing function evaluates the x axis to invert progress and the y axis to read
/// the eased value.
fn component(c1: f32, c2: f32, t: f32) f32 {
    const u = 1 - t;
    // B(t) = 3(1-t)^2 t c1 + 3(1-t) t^2 c2 + t^3, with P0 = 0 and P3 = 1.
    return 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t;
}

/// The derivative of `component` with respect to `t`, for the Newton step that
/// inverts the x axis.
fn slope(c1: f32, c2: f32, t: f32) f32 {
    const u = 1 - t;
    return 3 * u * u * c1 + 6 * u * t * (c2 - c1) + 3 * t * t * (1 - c2);
}

/// Solves for the parameter `t` at which the curve's x axis equals `progress`.
///
/// A timing bezier is given as a function of progress, but the curve is parametric, so
/// the parameter must be recovered first. Newton–Raphson converges fast for the
/// well-behaved timing curves in use; a few bisection fallback steps guarantee a
/// bounded, monotone bracket even if a pathological curve stalls Newton, so the solve
/// always terminates.
fn solveParameter(progress: f32, x1: f32, x2: f32) f32 {
    var t = progress; // progress is a good first guess for a near-diagonal curve
    var iteration: usize = 0;
    while (iteration < 8) : (iteration += 1) {
        const x = component(x1, x2, t) - progress;
        if (@abs(x) < 1e-6) return t;
        const d = slope(x1, x2, t);
        if (@abs(d) < 1e-6) break; // flat: hand off to bisection
        t -= x / d;
    }
    // Bisection fallback, bracketed to the unit interval.
    var low: f32 = 0;
    var high: f32 = 1;
    t = progress;
    iteration = 0;
    while (iteration < 24) : (iteration += 1) {
        const x = component(x1, x2, t);
        if (@abs(x - progress) < 1e-6) return t;
        if (x < progress) low = t else high = t;
        t = (low + high) / 2;
    }
    return t;
}

/// The eased value at `progress` along a cubic-bezier timing curve whose control
/// points are `(x1, y1)` and `(x2, y2)` (endpoints implicitly at 0 and 1).
///
/// Progress is clamped to the unit interval, but the returned value is not: a curve
/// whose `y2` exceeds 1 overshoots, and that overshoot is the whole point of a spring,
/// so it is preserved rather than clipped back to the endpoint.
pub fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32, progress: f32) f32 {
    const clamped = std.math.clamp(progress, 0, 1);
    if (clamped == 0) return 0;
    if (clamped == 1) return 1;
    const t = solveParameter(clamped, x1, x2);
    return component(y1, y2, t);
}

/// The shell's signature spring, evaluated at `progress`. Reads the reference control
/// points from the design theme — the single place the spring's shape is defined — so
/// the curve every animator uses and the curve the design specifies are one thing.
pub fn spring(progress: f32) f32 {
    const scale = 1000.0;
    return cubicBezier(
        @as(f32, @floatFromInt(theme.ease_spring_x1)) / scale,
        @as(f32, @floatFromInt(theme.ease_spring_y1)) / scale,
        @as(f32, @floatFromInt(theme.ease_spring_x2)) / scale,
        @as(f32, @floatFromInt(theme.ease_spring_y2)) / scale,
        progress,
    );
}

/// The motion policy, resolved from accessibility settings. Under `reduced`, curves are
/// substituted so no animation overshoots or oscillates — the vestibular-safe path.
pub const Reduce = enum { full, reduced };

/// The signature spring, resolved against the motion policy. Under `full` it is the
/// overshooting spring; under `reduced` it is substituted at resolve time with a gentle
/// non-overshooting ease-out, so a person who asked for reduced motion never sees the
/// bounce. The substitution happens here, once, so every animator that goes through the
/// spring inherits it.
pub fn springWith(progress: f32, reduce: Reduce) f32 {
    return switch (reduce) {
        .full => spring(progress),
        // A standard ease-out (no control point above 1), clamped: monotone, no overshoot.
        .reduced => std.math.clamp(cubicBezier(0.25, 0.1, 0.25, 1.0, progress), 0.0, 1.0),
    };
}

/// Linear interpolation between two scalars by a fraction. The fraction may exceed the
/// unit interval — a spring hands one past 1 at its overshoot — so this does not clamp.
pub fn lerp(from: f32, to: f32, fraction: f32) f32 {
    return from + (to - from) * fraction;
}

test "reduced motion substitutes the spring for a non-overshooting curve" {
    // Full spring overshoots past its target somewhere in the middle; reduced never does.
    var overshot_full = false;
    var overshot_reduced = false;
    var i: usize = 0;
    while (i <= 100) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 100.0;
        if (springWith(t, .full) > 1.0001) overshot_full = true;
        if (springWith(t, .reduced) > 1.0001) overshot_reduced = true;
    }
    try std.testing.expect(overshot_full); // the signature spring bounces
    try std.testing.expect(!overshot_reduced); // reduced motion does not
    // Both still travel end to end.
    try std.testing.expect(@abs(springWith(0, .reduced)) < 1e-4);
    try std.testing.expect(@abs(springWith(1, .reduced) - 1.0) < 1e-4);
}

/// Interpolates an integer coordinate, rounding to the nearest pixel so an animated
/// position lands on a whole pixel rather than a blurred fractional one.
pub fn lerpInt(from: i32, to: i32, fraction: f32) i32 {
    const value = lerp(@floatFromInt(from), @floatFromInt(to), fraction);
    return @intFromFloat(@round(value));
}

/// Interpolates a colour channel, clamped to a byte: a spring's overshoot must not
/// wrap a channel past its range into a wrong hue.
fn lerpChannel(from: u8, to: u8, fraction: f32) u8 {
    const value = lerp(@floatFromInt(from), @floatFromInt(to), fraction);
    return @intFromFloat(std.math.clamp(@round(value), 0, 255));
}

/// Interpolates between two colours, channel by channel including alpha. Colour is
/// clamped even though position is not, because a colour past its range is a defect
/// while a position past its target is the intended overshoot.
pub fn lerpColour(from: Colour, to: Colour, fraction: f32) Colour {
    return .{
        .red = lerpChannel(from.red, to.red, fraction),
        .green = lerpChannel(from.green, to.green, fraction),
        .blue = lerpChannel(from.blue, to.blue, fraction),
        .alpha = lerpChannel(from.alpha, to.alpha, fraction),
    };
}

/// Interpolates between two affine transforms component by component. This is correct
/// for the translations and axis scales an interface animates; a transform carrying
/// rotation would need its rotation decomposed and slerped, which the reference motion
/// does not use, so the honest, simple thing is a component lerp with that caveat
/// stated rather than a wrong rotation blend hidden behind a fancier signature.
pub fn lerpTransform(from: Transform, to: Transform, fraction: f32) Transform {
    return .{
        .a = lerp(from.a, to.a, fraction),
        .b = lerp(from.b, to.b, fraction),
        .c = lerp(from.c, to.c, fraction),
        .d = lerp(from.d, to.d, fraction),
        .tx = lerp(from.tx, to.tx, fraction),
        .ty = lerp(from.ty, to.ty, fraction),
    };
}

/// The eased value at `progress` for a motion, with reduced motion honoured by
/// substituting the curve rather than removing the change.
///
/// When a person has asked for less motion, the answer is not to freeze — a surface
/// that simply stopped moving would leave them unable to tell that anything happened.
/// Instead the curve is substituted: the springy, overshooting motion becomes a plain
/// linear cross-fade over the same progress, so the state change still reads but the
/// movement that conveys it is quieted. This is the one place a motion's shape is
/// chosen, so the substitution happens once, at resolve time, for every animator.
pub fn easedForMotion(progress: f32, reduce_motion: bool) f32 {
    if (reduce_motion) {
        // A plain linear fade: the change is still conveyed, the movement is not.
        return std.math.clamp(progress, 0, 1);
    }
    return spring(progress);
}

// --- Tests ---

const testing = std.testing;

test "a timing curve is pinned at both ends" {
    // Whatever the control points, progress 0 eases to 0 and progress 1 to 1.
    try testing.expectEqual(@as(f32, 0), cubicBezier(0.2, 0.9, 0.25, 1.1, 0));
    try testing.expectEqual(@as(f32, 1), cubicBezier(0.2, 0.9, 0.25, 1.1, 1));
}

test "the signature spring overshoots before it settles" {
    // The spring's y2 exceeds 1, so somewhere in the middle the eased value passes 1
    // and comes back — the settle that makes the motion feel physical.
    var overshot = false;
    var progress: f32 = 0;
    while (progress <= 1.0) : (progress += 0.02) {
        if (spring(progress) > 1.0001) overshot = true;
    }
    try testing.expect(overshot);
    // It still ends exactly at its target.
    try testing.expectEqual(@as(f32, 1), spring(1));
}

test "solving the curve's x axis recovers progress" {
    // For a sampling of progress values, evaluating x at the solved parameter returns
    // the progress — the inversion the timing function depends on.
    const x1 = 0.42;
    const x2 = 0.58;
    var progress: f32 = 0.05;
    while (progress < 1.0) : (progress += 0.1) {
        const t = solveParameter(progress, x1, x2);
        try testing.expectApproxEqAbs(progress, component(x1, x2, t), 1e-4);
    }
}

test "a linear timing curve eases to its input" {
    // Control points on the diagonal make the curve the identity.
    var progress: f32 = 0;
    while (progress <= 1.0) : (progress += 0.1) {
        try testing.expectApproxEqAbs(progress, cubicBezier(1.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0, progress), 1e-3);
    }
}

test "scalar interpolation reaches both endpoints and the midpoint" {
    try testing.expectEqual(@as(f32, 10), lerp(10, 20, 0));
    try testing.expectEqual(@as(f32, 20), lerp(10, 20, 1));
    try testing.expectEqual(@as(f32, 15), lerp(10, 20, 0.5));
    // Overshoot is preserved for a spring past its target.
    try testing.expectEqual(@as(f32, 22), lerp(10, 20, 1.2));
}

test "integer interpolation rounds to a whole pixel" {
    try testing.expectEqual(@as(i32, 5), lerpInt(0, 10, 0.5));
    try testing.expectEqual(@as(i32, 3), lerpInt(0, 10, 0.33)); // 3.3 -> 3
    try testing.expectEqual(@as(i32, 7), lerpInt(0, 10, 0.67)); // 6.7 -> 7
}

test "colour interpolation moves each channel and clamps against overshoot" {
    const black: Colour = .{ .red = 0, .green = 0, .blue = 0, .alpha = 255 };
    const white: Colour = .{ .red = 255, .green = 255, .blue = 255, .alpha = 255 };
    const mid = lerpColour(black, white, 0.5);
    try testing.expectEqual(@as(u8, 128), mid.red); // 127.5 -> 128
    // An overshoot fraction cannot push a channel past its byte range.
    const over = lerpColour(black, white, 1.5);
    try testing.expectEqual(@as(u8, 255), over.red);
}

test "colour interpolation carries alpha" {
    const clear: Colour = .{ .red = 100, .green = 100, .blue = 100, .alpha = 0 };
    const solid: Colour = .{ .red = 100, .green = 100, .blue = 100, .alpha = 255 };
    try testing.expectEqual(@as(u8, 128), lerpColour(clear, solid, 0.5).alpha);
}

test "transform interpolation moves translation and scale to the midpoint" {
    const from = Transform.identity;
    const to = Transform{ .a = 2, .b = 0, .c = 0, .d = 2, .tx = 10, .ty = 20 };
    const mid = lerpTransform(from, to, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), mid.a, 1e-6); // scale 1 -> 2
    try testing.expectApproxEqAbs(@as(f32, 5), mid.tx, 1e-6); // translate 0 -> 10
    try testing.expectApproxEqAbs(@as(f32, 10), mid.ty, 1e-6);
}

test "reduced motion substitutes a linear fade for the spring but keeps the change" {
    // Under reduced motion the eased value is exactly the (clamped) progress — a plain
    // fade — and never overshoots, while the full motion springs past 1 somewhere.
    var progress: f32 = 0;
    var full_overshot = false;
    while (progress <= 1.0) : (progress += 0.02) {
        try testing.expectApproxEqAbs(std.math.clamp(progress, 0, 1), easedForMotion(progress, true), 1e-6);
        if (easedForMotion(progress, false) > 1.0001) full_overshot = true;
    }
    try testing.expect(full_overshot);
    // Both still reach the endpoints — the state change is conveyed either way.
    try testing.expectEqual(@as(f32, 1), easedForMotion(1, true));
    try testing.expectEqual(@as(f32, 1), easedForMotion(1, false));
}
