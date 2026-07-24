//! Computing an animation's progress at a moment in time, clamped and monotonic, so an
//! animation always ends where it should and never runs backward or past its bounds.
//!
//! An animation is a value moving from a start to an end over a duration, and the whole
//! of it comes down to one number: the progress fraction at a given time, between zero at
//! the start and one at the end. Two things about that fraction must hold or the motion
//! looks broken. It must be clamped: before the animation starts the fraction is zero and
//! after it ends the fraction is one, so a value queried early or late sits exactly at the
//! endpoint rather than overshooting into an impossible position. And an easing curve
//! applied to it must be monotonic and pinned at the ends — it may accelerate and
//! decelerate, but it must start at zero, end at one, and never go backward, or the
//! animation appears to jump back before finishing. Get the fraction right and the value
//! it drives is right; get it wrong and the interface twitches.
//!
//! This module animates nothing. It computes the clamped linear progress fraction and
//! applies a bounded easing curve to it, as pure functions over time.

const std = @import("std");

/// The raw progress fraction of an animation at `elapsed_ms` into a `duration_ms`
/// animation, clamped to the closed unit interval.
///
/// Before the animation (or a zero-length one) the fraction is zero; at or after its end
/// it is one; in between it is the linear ratio. Clamping is what keeps a value queried
/// early or late from overshooting its endpoints — the animation is exactly at its start
/// or its end, never beyond.
pub fn progress(elapsed_ms: i64, duration_ms: i64) f32 {
    if (duration_ms <= 0) return 1.0; // a zero-duration animation is instantly complete
    if (elapsed_ms <= 0) return 0.0;
    if (elapsed_ms >= duration_ms) return 1.0;
    return @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(duration_ms));
}

/// An easing curve applied to a linear fraction.
pub const Easing = enum {
    /// No easing: the fraction is used as-is.
    linear,
    /// Accelerates from rest: slow start, fast finish. Quadratic.
    ease_in,
    /// Decelerates to rest: fast start, slow finish. Quadratic.
    ease_out,
    /// Accelerates then decelerates: slow at both ends.
    ease_in_out,
};

/// Applies an easing curve to a linear fraction, returning the eased fraction.
///
/// The input is assumed already clamped to the unit interval. Every curve is pinned at
/// the ends — easing zero yields zero and easing one yields one — and is monotonic, so an
/// eased animation still starts at its start, ends at its end, and never appears to run
/// backward, however it accelerates in between.
pub fn ease(easing: Easing, t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return switch (easing) {
        .linear => x,
        .ease_in => x * x,
        .ease_out => 1.0 - (1.0 - x) * (1.0 - x),
        .ease_in_out => if (x < 0.5) 2.0 * x * x else 1.0 - std.math.pow(f32, -2.0 * x + 2.0, 2.0) / 2.0,
    };
}

test "progress is zero before the start and one after the end" {
    try std.testing.expectEqual(@as(f32, 0.0), progress(-10, 1000));
    try std.testing.expectEqual(@as(f32, 0.0), progress(0, 1000));
    try std.testing.expectEqual(@as(f32, 1.0), progress(1000, 1000));
    try std.testing.expectEqual(@as(f32, 1.0), progress(2000, 1000));
}

test "progress is the linear ratio in between" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), progress(250, 1000), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), progress(500, 1000), 0.001);
}

test "a zero-duration animation is instantly complete" {
    try std.testing.expectEqual(@as(f32, 1.0), progress(0, 0));
    try std.testing.expectEqual(@as(f32, 1.0), progress(100, 0));
}

test "every easing is pinned at both ends" {
    for (std.enums.values(Easing)) |easing| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), ease(easing, 0.0), 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease(easing, 1.0), 0.001);
    }
}

test "easing clamps its input" {
    // An out-of-range input is clamped before easing, so it never overshoots.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ease(.ease_in, -0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease(.ease_out, 1.5), 0.001);
}

test "progress is always within the unit interval, swept" {
    const times = [_]i64{ -100, 0, 100, 500, 999, 1000, 5000 };
    for (times) |t| {
        const p = progress(t, 1000);
        try std.testing.expect(p >= 0.0 and p <= 1.0);
    }
}

test "every easing is monotonic non-decreasing, swept" {
    // The no-backward property: as the fraction increases, every eased value does not
    // decrease, so an animation never appears to run backward.
    for (std.enums.values(Easing)) |easing| {
        var previous: f32 = 0.0;
        var i: u32 = 0;
        while (i <= 100) : (i += 1) {
            const x = @as(f32, @floatFromInt(i)) / 100.0;
            const y = ease(easing, x);
            try std.testing.expect(y >= previous - 0.0001);
            previous = y;
        }
    }
}
