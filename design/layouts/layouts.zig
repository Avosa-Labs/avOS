//! Resolving a viewport width into a layout breakpoint and keeping content within the safe
//! area, so a layout adapts to the screen and never draws under a notch or a rounded corner.
//!
//! A layout has to work across a range of screens — a narrow phone, a wide phone, a tablet —
//! and the way it adapts is by breakpoints: bands of viewport width, each mapping to a
//! layout that suits it, so a one-column phone layout becomes a two-column tablet one at the
//! right size rather than stretching awkwardly. Choosing the band is a decision on the
//! viewport width against ordered thresholds. Separately, a screen is not a clean rectangle:
//! notches, camera cutouts, and rounded corners carve insets out of the edges, the safe
//! area, and content drawn into those insets is clipped or hidden. So a layout also resolves
//! its usable region by subtracting the safe-area insets from the viewport, and content is
//! placed only within what remains. Together these make a layout fit both the size and the
//! shape of the screen it lands on.
//!
//! This module lays out nothing. It resolves a viewport width into a breakpoint and computes
//! the safe content region, as pure functions.

const std = @import("std");

/// A layout breakpoint: the band of viewport width a layout is designed for, from narrow to
/// wide.
pub const Breakpoint = enum {
    /// A compact phone width.
    compact,
    /// A wide phone or small foldable.
    regular,
    /// A tablet or large display.
    expanded,
};

/// The viewport width, in points, at or above which each larger breakpoint begins.
pub const regular_min_points: u32 = 480;
pub const expanded_min_points: u32 = 840;

/// Resolves a viewport width into its breakpoint.
///
/// The width is compared against the ordered thresholds: below the regular minimum it is
/// compact, at or above the expanded minimum it is expanded, and in between it is regular. A
/// wider viewport never resolves to a narrower breakpoint, so the mapping is monotone.
pub fn breakpoint(viewport_width_points: u32) Breakpoint {
    if (viewport_width_points >= expanded_min_points) return .expanded;
    if (viewport_width_points >= regular_min_points) return .regular;
    return .compact;
}

/// The safe-area insets a screen's shape carves out of each edge, in points.
pub const Insets = struct {
    top: u32,
    bottom: u32,
    left: u32,
    right: u32,
};

/// A rectangular region in points.
pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Computes the safe content region: the viewport with the safe-area insets removed from
/// each edge.
///
/// The insets are subtracted from the viewport's edges, saturating so an inset larger than
/// the viewport yields a zero dimension rather than wrapping. Content placed within the
/// returned region never falls under a notch, cutout, or rounded corner, because those are
/// exactly what the insets describe.
pub fn safeRegion(viewport_width: u32, viewport_height: u32, insets: Insets) Region {
    const width = viewport_width -| insets.left -| insets.right;
    const height = viewport_height -| insets.top -| insets.bottom;
    return .{ .x = insets.left, .y = insets.top, .width = width, .height = height };
}

test "narrow widths are compact" {
    try std.testing.expectEqual(Breakpoint.compact, breakpoint(0));
    try std.testing.expectEqual(Breakpoint.compact, breakpoint(regular_min_points - 1));
}

test "mid widths are regular" {
    try std.testing.expectEqual(Breakpoint.regular, breakpoint(regular_min_points));
    try std.testing.expectEqual(Breakpoint.regular, breakpoint(expanded_min_points - 1));
}

test "wide widths are expanded" {
    try std.testing.expectEqual(Breakpoint.expanded, breakpoint(expanded_min_points));
    try std.testing.expectEqual(Breakpoint.expanded, breakpoint(2000));
}

test "the safe region subtracts the insets" {
    const region = safeRegion(1000, 2000, .{ .top = 50, .bottom = 30, .left = 10, .right = 10 });
    try std.testing.expectEqual(@as(u32, 10), region.x);
    try std.testing.expectEqual(@as(u32, 50), region.y);
    try std.testing.expectEqual(@as(u32, 980), region.width); // 1000 - 10 - 10
    try std.testing.expectEqual(@as(u32, 1920), region.height); // 2000 - 50 - 30
}

test "insets larger than the viewport yield a zero dimension, not a wrap" {
    const region = safeRegion(100, 100, .{ .top = 60, .bottom = 60, .left = 0, .right = 0 });
    try std.testing.expectEqual(@as(u32, 0), region.height);
}

test "the breakpoint is monotone in width, swept" {
    // A wider viewport never yields a narrower breakpoint.
    var width: u32 = 0;
    var previous: u8 = 0;
    while (width <= 1200) : (width += 40) {
        const rank = @intFromEnum(breakpoint(width));
        try std.testing.expect(rank >= previous);
        previous = rank;
    }
}

test "the safe region always fits within the viewport, swept" {
    // The no-overdraw property: the region plus its origin never exceeds the viewport.
    const insets_list = [_]Insets{
        .{ .top = 0, .bottom = 0, .left = 0, .right = 0 },
        .{ .top = 44, .bottom = 34, .left = 0, .right = 0 },
        .{ .top = 200, .bottom = 200, .left = 200, .right = 200 },
    };
    for (insets_list) |insets| {
        const region = safeRegion(400, 800, insets);
        try std.testing.expect(region.x + region.width <= 400);
        try std.testing.expect(region.y + region.height <= 800);
    }
}
