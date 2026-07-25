//! Geometry as semantic tokens: the spacing, corner, elevation, and motion-curve
//! roles a surface asks for by meaning, so the one grid, one corner family, and one
//! signature spring are defined in a single place rather than re-guessed per surface.
//!
//! Colour is not the only thing a design system must hold as a single source of truth;
//! geometry drifts the same way and just as visibly. A layout that hard-codes an
//! eight-point gap here and a nine-point gap there reads as sloppy even when nothing
//! is "wrong", and a corner radius chosen per component is how an interface loses its
//! coherence. So spacing is steps of one grid, corners are a small closed scale,
//! elevation is a defined shadow rather than an ad-hoc blur, and the motion curve is
//! one bezier — all named by role. A surface that wants "the medium corner" or "the
//! settle spring" asks for the role and gets the one value the whole system shares.
//!
//! This module holds values, not logic. It defines the geometry roles and the
//! concrete geometry the reference resolves them to, as plain data a brand resolution
//! reads.

const std = @import("std");

/// The base spacing step in logical points. Every gap and margin is a whole multiple
/// of this, so the layout sits on one grid.
pub const spacing_step: u16 = 8;

/// A spacing role, resolved to a whole number of grid steps.
pub const SpacingRole = enum {
    /// Hairline gaps within a control.
    tight,
    /// The default gap between related elements.
    snug,
    /// The gap between distinct groups.
    comfortable,
    /// The margin around a screen's content.
    roomy,

    pub fn steps(role: SpacingRole) u16 {
        return switch (role) {
            .tight => 1,
            .snug => 2,
            .comfortable => 3,
            .roomy => 4,
        };
    }

    /// The role's gap in logical points: its step count times the grid step.
    pub fn points(role: SpacingRole) u16 {
        return role.steps() * spacing_step;
    }
};

/// A corner-radius role, resolved to a radius in logical points. A closed scale, so
/// every rounded thing shares the same small family of curves.
pub const RadiusRole = enum {
    sm,
    md,
    lg,
    xl,
    /// A fully rounded pill.
    pill,

    pub fn points(role: RadiusRole) u16 {
        return switch (role) {
            .sm => 8,
            .md => 12,
            .lg => 16,
            .xl => 20,
            .pill => 22,
        };
    }
};

/// The fraction of an icon tile's side used as its superellipse corner radius — the
/// continuous-curvature squircle the reference paints its tiles with.
pub const icon_radius_ratio_num: u16 = 23;
pub const icon_radius_ratio_den: u16 = 100;

/// The soft elevation shadow a raised surface casts: its blur radius and vertical
/// offset in points, and its tint. One shadow, so elevation reads consistently.
pub const Elevation = struct {
    blur: u16,
    offset_y: i16,
    tint_red: u8,
    tint_green: u8,
    tint_blue: u8,
    tint_alpha: u8,
};

/// A cubic-bezier motion curve, as control points scaled by 1000 so it is exact
/// integer data. The reference's signature spring overshoots — `y2` exceeds 1000 — so
/// a surface settles into place rather than snapping to it.
pub const Curve = struct {
    x1: i16,
    y1: i16,
    x2: i16,
    y2: i16,

    /// Whether the curve overshoots its target (a spring settle) rather than easing
    /// monotonically to it.
    pub fn overshoots(curve: Curve) bool {
        return curve.y1 > 1000 or curve.y2 > 1000;
    }
};

// --- Tests ---

const testing = std.testing;

test "spacing roles are whole multiples of the one grid step" {
    for (std.enums.values(SpacingRole)) |role| {
        try testing.expectEqual(@as(u16, 0), role.points() % spacing_step);
        try testing.expect(role.steps() > 0);
    }
}

test "spacing grows monotonically across the roles" {
    var previous: u16 = 0;
    for (std.enums.values(SpacingRole)) |role| {
        try testing.expect(role.points() > previous);
        previous = role.points();
    }
}

test "the corner scale is closed and increasing up to the pill" {
    try testing.expect(RadiusRole.sm.points() < RadiusRole.md.points());
    try testing.expect(RadiusRole.md.points() < RadiusRole.lg.points());
    try testing.expect(RadiusRole.lg.points() < RadiusRole.xl.points());
    try testing.expect(RadiusRole.xl.points() <= RadiusRole.pill.points());
}

test "a spring curve is recognised by its overshoot" {
    const spring: Curve = .{ .x1 = 200, .y1 = 900, .x2 = 250, .y2 = 1100 };
    const ease: Curve = .{ .x1 = 250, .y1 = 100, .x2 = 250, .y2 = 1000 };
    try testing.expect(spring.overshoots());
    try testing.expect(!ease.overshoots());
}
