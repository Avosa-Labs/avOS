//! Deciding which surfaces actually need drawing, so the compositor skips a surface
//! that something opaque completely covers rather than painting pixels no one will see.
//!
//! The compositor stacks surfaces back to front and produces the final image, and the
//! cheapest pixel is the one never drawn. A surface entirely hidden behind an opaque
//! surface above it contributes nothing to the result — every one of its pixels is
//! overwritten — so drawing it is wasted work and, on a battery device, wasted power.
//! Occlusion culling is the decision to skip it. The rule has to be careful in exactly
//! one direction: a surface may be skipped only when it is *fully* covered by something
//! *fully opaque*, because a covering surface with any transparency lets the one beneath
//! show through, and a partial cover leaves an edge visible. Get that wrong and content
//! vanishes from the screen. So the compositor culls conservatively — skip only what is
//! provably invisible — and draws everything else.
//!
//! This module composites nothing. It decides whether a surface is occluded by those
//! above it, as a pure function over their bounds and opacity, so the never-drop-visible
//! rule holds in one place.

const std = @import("std");

/// An axis-aligned rectangle in screen pixels. `x`,`y` is the top-left; width and height
/// extend right and down.
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    fn right(rect: Rect) i64 {
        return @as(i64, rect.x) + rect.width;
    }
    fn bottom(rect: Rect) i64 {
        return @as(i64, rect.y) + rect.height;
    }

    /// Whether this rectangle fully contains another: the other lies entirely within it.
    fn contains(rect: Rect, other: Rect) bool {
        return other.x >= rect.x and other.y >= rect.y and
            other.right() <= rect.right() and other.bottom() <= rect.bottom();
    }
};

/// A surface in the stack.
pub const Surface = struct {
    bounds: Rect,
    /// Whether the surface is fully opaque. Only a fully opaque surface can occlude
    /// what is beneath it; any transparency lets the surface below show through.
    opaque_surface: bool,
};

/// Whether a surface is occluded — fully hidden — by the surfaces stacked above it.
///
/// A surface is occluded only if some single surface above it is fully opaque and fully
/// contains its bounds. That is the conservative condition: a covering surface with any
/// transparency does not occlude, and a cover that does not fully contain the surface
/// leaves part of it visible. Anything not provably occluded is treated as visible and
/// must be drawn, so content is never dropped by an over-eager cull.
pub fn occluded(surface: Surface, above: []const Surface) bool {
    for (above) |cover| {
        if (cover.opaque_surface and cover.bounds.contains(surface.bounds)) return true;
    }
    return false;
}

fn surf(x: i32, y: i32, w: u32, h: u32, is_opaque: bool) Surface {
    return .{ .bounds = .{ .x = x, .y = y, .width = w, .height = h }, .opaque_surface = is_opaque };
}

test "a surface fully covered by an opaque one is occluded" {
    const under = surf(10, 10, 100, 100, true);
    const cover = surf(0, 0, 200, 200, true);
    try std.testing.expect(occluded(under, &.{cover}));
}

test "a surface under a transparent cover is not occluded" {
    const under = surf(10, 10, 100, 100, true);
    const cover = surf(0, 0, 200, 200, false); // transparent
    try std.testing.expect(!occluded(under, &.{cover}));
}

test "a partially covering surface does not occlude" {
    const under = surf(10, 10, 100, 100, true);
    const cover = surf(0, 0, 50, 50, true); // covers only the corner
    try std.testing.expect(!occluded(under, &.{cover}));
}

test "an exactly-matching opaque cover occludes" {
    const under = surf(10, 10, 100, 100, true);
    const cover = surf(10, 10, 100, 100, true);
    try std.testing.expect(occluded(under, &.{cover}));
}

test "occlusion by any one of several covers is enough" {
    const under = surf(10, 10, 100, 100, true);
    const covers = [_]Surface{
        surf(0, 0, 20, 20, true), // too small
        surf(0, 0, 300, 300, true), // fully covers
    };
    try std.testing.expect(occluded(under, &covers));
}

test "nothing above means visible" {
    const under = surf(10, 10, 100, 100, true);
    try std.testing.expect(!occluded(under, &.{}));
}

test "a surface is culled only when provably fully hidden, swept" {
    // The never-drop-visible property: a surface reported occluded is always fully
    // contained by some fully-opaque cover.
    const under = surf(20, 20, 60, 60, true);
    const covers = [_]Surface{
        surf(0, 0, 200, 200, true), // opaque, contains
        surf(0, 0, 200, 200, false), // transparent, contains
        surf(30, 30, 10, 10, true), // opaque, does not contain
    };
    for (covers) |cover| {
        if (occluded(under, &.{cover})) {
            try std.testing.expect(cover.opaque_surface and cover.bounds.contains(under.bounds));
        }
    }
}
