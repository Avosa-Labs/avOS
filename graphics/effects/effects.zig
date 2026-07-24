//! Bounding visual effects, so a blur radius or an effect stack can make a surface
//! prettier without becoming a way to melt the GPU.
//!
//! Effects — blur, shadow, colour adjustment — cost real GPU time, and their cost is not
//! flat. A blur's cost grows with its radius, and a large radius on a large surface is an
//! enormous amount of sampling; an effect stack applies each effect in turn, so a chain
//! of them multiplies. Left unbounded, an effect is a denial-of-service the interface
//! inflicts on itself: a hostile or careless caller sets a blur radius of ten thousand
//! and the frame never finishes. So effects are bounded. A blur radius past a sane
//! maximum is clamped to that maximum rather than honoured, because no legitimate blur
//! needs to be that large and honouring it would blow the frame. An effect stack longer
//! than a small limit is refused, because past a handful of chained effects the cost is
//! not worth the barely-visible result. The surface still gets its effect; it just cannot
//! use one to run the GPU dry.
//!
//! This module renders no effect. It clamps a blur radius into range and decides whether
//! an effect stack fits its length bound, as pure functions.

const std = @import("std");

/// The largest blur radius, in pixels, that will be honoured. Past this the cost grows
/// without a matching visible benefit, so a larger request is clamped here.
pub const max_blur_radius: u32 = 128;

/// The most effects that may be chained on one surface. A short cap, because each added
/// effect is another full pass over the surface and the benefit falls off fast.
pub const max_effect_stack: usize = 8;

/// Clamps a blur radius to the honoured maximum. A radius within range is used as-is; one
/// beyond it is held at the maximum, so an absurd radius cannot blow the frame while a
/// reasonable one is unaffected.
pub fn clampBlurRadius(requested: u32) u32 {
    return @min(requested, max_blur_radius);
}

/// The outcome of admitting an effect stack.
pub const StackDecision = enum {
    /// The stack fits the length bound and may be applied.
    apply,
    /// The stack is longer than the bound; it is refused rather than costing an
    /// unbounded number of passes.
    too_long,

    pub fn applies(decision: StackDecision) bool {
        return decision == .apply;
    }
};

/// Decides whether an effect stack of `count` effects may be applied.
///
/// A stack within the length bound is applied; one longer is refused, because past the
/// bound each additional effect is another full pass over the surface for a benefit that
/// no longer justifies the cost.
pub fn admitStack(count: usize) StackDecision {
    if (count > max_effect_stack) return .too_long;
    return .apply;
}

test "a reasonable blur radius is unchanged" {
    try std.testing.expectEqual(@as(u32, 16), clampBlurRadius(16));
    try std.testing.expectEqual(max_blur_radius, clampBlurRadius(max_blur_radius));
}

test "an excessive blur radius is clamped, not honoured" {
    try std.testing.expectEqual(max_blur_radius, clampBlurRadius(10_000));
    try std.testing.expectEqual(max_blur_radius, clampBlurRadius(max_blur_radius + 1));
}

test "an effect stack within the bound applies" {
    try std.testing.expectEqual(StackDecision.apply, admitStack(3));
    try std.testing.expectEqual(StackDecision.apply, admitStack(max_effect_stack));
}

test "an effect stack past the bound is refused" {
    try std.testing.expectEqual(StackDecision.too_long, admitStack(max_effect_stack + 1));
}

test "an empty stack applies" {
    try std.testing.expectEqual(StackDecision.apply, admitStack(0));
}

test "no blur radius is ever honoured past the maximum, swept" {
    const radii = [_]u32{ 0, 1, 64, max_blur_radius, max_blur_radius + 1, 100_000 };
    for (radii) |radius| {
        try std.testing.expect(clampBlurRadius(radius) <= max_blur_radius);
    }
}

test "no stack past the bound ever applies, swept" {
    var count: usize = 0;
    while (count <= max_effect_stack + 4) : (count += 1) {
        if (admitStack(count).applies()) try std.testing.expect(count <= max_effect_stack);
    }
}
