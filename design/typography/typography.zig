//! Resolving a type-scale step into a font size, so text sizes come from a consistent
//! ramp and never fall below what is legible.
//!
//! A design system does not let a designer type any font size they like; it defines a
//! scale — a ramp of steps, each a fixed ratio above the last — so that sizes across the
//! whole interface relate to each other and nothing is an arbitrary one-off. The ramp is
//! anchored on a base size and a ratio, and a step number picks a size on it. Two rules
//! keep the ramp usable. It has a floor: no step resolves to a size below the smallest
//! legible size, because text a person cannot read is not a smaller heading, it is a bug.
//! And it honours the person's preferred text size — a global scale factor for larger
//! type — by multiplying through, so someone who needs bigger text gets it everywhere at
//! once rather than app by app. The size a step produces is therefore consistent, legible,
//! and respectful of what the person asked for.
//!
//! This module renders no glyphs. It resolves a scale step and a user scale factor into a
//! font size, clamped to the legible minimum, as a pure function.

const std = @import("std");

/// The smallest font size, in points, that is considered legible. No resolved size falls
/// below this, whatever the step.
pub const min_legible_points: f32 = 11.0;

/// The type scale: a base size and the ratio between steps.
pub const Scale = struct {
    /// The size of step zero, in points.
    base_points: f32,
    /// The multiplier between adjacent steps. Above 1; a typographic scale is often near
    /// 1.125 to 1.25.
    ratio: f32,

    /// The unscaled size of a step, base times the ratio raised to the step. Negative
    /// steps produce smaller sizes, positive ones larger.
    fn stepSize(scale: Scale, step: i32) f32 {
        return scale.base_points * std.math.pow(f32, scale.ratio, @floatFromInt(step));
    }
};

/// Resolves a scale step into a final font size, applying the user's text-size factor and
/// clamping to the legible minimum.
///
/// The step's size on the ramp is multiplied by the user scale factor — a global
/// preference so larger text takes effect everywhere — and then held at the legible
/// minimum if it would fall below it. The result is a size that is on the ramp, scaled to
/// the person's preference, and never illegibly small.
pub fn resolve(scale: Scale, step: i32, user_scale: f32) f32 {
    const scaled = scale.stepSize(step) * user_scale;
    return @max(scaled, min_legible_points);
}

const body: Scale = .{ .base_points = 16.0, .ratio = 1.25 };

test "step zero is the base size" {
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), resolve(body, 0, 1.0), 0.01);
}

test "a positive step is larger by the ratio" {
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), resolve(body, 1, 1.0), 0.01); // 16 * 1.25
}

test "a small negative step is clamped to the legible minimum" {
    // 16 * 1.25^-3 is about 8.2, below the 11pt floor.
    try std.testing.expectEqual(min_legible_points, resolve(body, -3, 1.0));
}

test "the user scale factor enlarges text" {
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), resolve(body, 0, 1.5), 0.01); // 16 * 1.5
}

test "the user scale factor cannot shrink below the legible minimum" {
    // A tiny user scale would drop below the floor; the floor holds.
    try std.testing.expectEqual(min_legible_points, resolve(body, 0, 0.1));
}

test "no resolved size is ever below the legible minimum, swept" {
    // The legibility floor: across steps and user scales, no size falls below the
    // minimum.
    var step: i32 = -5;
    while (step <= 5) : (step += 1) {
        const scales = [_]f32{ 0.1, 0.5, 1.0, 2.0 };
        for (scales) |user_scale| {
            try std.testing.expect(resolve(body, step, user_scale) >= min_legible_points);
        }
    }
}

test "sizes increase monotonically with step above the floor, swept" {
    // On the part of the ramp above the floor, a higher step is never smaller.
    var step: i32 = 0;
    var previous: f32 = 0;
    while (step <= 6) : (step += 1) {
        const size = resolve(body, step, 1.0);
        try std.testing.expect(size >= previous);
        previous = size;
    }
}
