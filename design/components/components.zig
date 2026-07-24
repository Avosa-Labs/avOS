//! Deciding whether an interactive component is large enough to touch reliably, so a
//! button no one can hit accurately never ships.
//!
//! A touch target that is too small is not a cosmetic flaw, it is a component that fails at
//! its one job: a person aims for it and misses, hits the thing next to it, or gives up.
//! Fingers are imprecise, and there is a well-established minimum size below which reliable
//! tapping falls apart — around forty-four points on a side. A design system enforces that
//! minimum as a checkable rule rather than trusting each screen to get it right, because the
//! failure is invisible to a designer with a mouse and a large display and painful to a
//! person with a thumb on a phone in motion. The visual size of a control may be smaller for
//! the look of it, but its *hit target* — the region that actually responds to a touch — must
//! meet the minimum, expanding beyond the visible bounds if needed. So a component declares
//! its hit target, and one below the minimum on either axis is rejected, so every shipped
//! control is one a person can actually hit.
//!
//! This module lays out nothing. It decides whether a component's hit target meets the
//! minimum touch size, as a pure function.

const std = @import("std");

/// The minimum touch-target size, in points, on each axis for a reliably tappable control.
pub const min_touch_points: u32 = 44;

/// A component's hit target — the region that responds to touch, which may be larger than
/// its visible bounds.
pub const HitTarget = struct {
    width_points: u32,
    height_points: u32,

    /// Whether the hit target meets the minimum on both axes. A target smaller than the
    /// minimum on either axis is too small to hit reliably.
    pub fn meetsMinimum(target: HitTarget) bool {
        return target.width_points >= min_touch_points and target.height_points >= min_touch_points;
    }

    /// Expands a hit target to the minimum on each axis, growing a too-small target rather
    /// than shipping it. A target already at or above the minimum is unchanged.
    pub fn expandedToMinimum(target: HitTarget) HitTarget {
        return .{
            .width_points = @max(target.width_points, min_touch_points),
            .height_points = @max(target.height_points, min_touch_points),
        };
    }
};

test "a large-enough target meets the minimum" {
    try std.testing.expect((HitTarget{ .width_points = 48, .height_points = 48 }).meetsMinimum());
    try std.testing.expect((HitTarget{ .width_points = min_touch_points, .height_points = min_touch_points }).meetsMinimum());
}

test "a target too small on one axis fails" {
    try std.testing.expect(!(HitTarget{ .width_points = 44, .height_points = 20 }).meetsMinimum());
    try std.testing.expect(!(HitTarget{ .width_points = 20, .height_points = 44 }).meetsMinimum());
}

test "a small target expands to the minimum on both axes" {
    const expanded = (HitTarget{ .width_points = 20, .height_points = 20 }).expandedToMinimum();
    try std.testing.expectEqual(min_touch_points, expanded.width_points);
    try std.testing.expectEqual(min_touch_points, expanded.height_points);
    try std.testing.expect(expanded.meetsMinimum());
}

test "an adequate target is unchanged by expansion" {
    const target: HitTarget = .{ .width_points = 60, .height_points = 50 };
    const expanded = target.expandedToMinimum();
    try std.testing.expectEqual(target.width_points, expanded.width_points);
    try std.testing.expectEqual(target.height_points, expanded.height_points);
}

test "an expanded target always meets the minimum, swept" {
    // The tappability property: whatever the input size, expansion produces a target that
    // meets the minimum.
    const sizes = [_]u32{ 0, 10, 44, 44, 100 };
    for (sizes) |w| {
        for (sizes) |h| {
            const expanded = (HitTarget{ .width_points = w, .height_points = h }).expandedToMinimum();
            try std.testing.expect(expanded.meetsMinimum());
        }
    }
}
