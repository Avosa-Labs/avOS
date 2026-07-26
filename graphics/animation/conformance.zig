//! Motion conformance: the animation curves are the design's curves, evaluated.
//!
//! This closes the gap the whole rebuild is atoning for — a signature spring that was
//! defined but never checked against the design. Two things are asserted. First, the token
//! spring's control points must equal the design's extracted signature spring: a drift
//! catcher at the source, like the colour reference map. Second — and this is CP3(b) — the
//! interpolator is *sampled* across the unit interval and each eased value must match the
//! design curve within tolerance. That is what makes a wrong-but-smooth spring fail: right
//! endpoints are not enough, the shape in between must be the design's shape.
//!
//! The N and the tolerance are concrete, recorded in docs/performance-budget.md, not
//! inherited-vague.

const std = @import("std");
const interpolate = @import("interpolate.zig");
const theme = @import("design").theme;

/// The design's signature spring control points, from test-vectors/design/motion.zon
/// (`.2,.9,.25,1.1`) — the reviewed binding to the token spring.
const design_signature_spring = [4]f32{ 0.2, 0.9, 0.25, 1.1 };

/// Motion-shape sampling parameters (docs/performance-budget.md, motion conformance).
const sample_points: usize = 33;
const shape_tolerance: f32 = 1.0e-3;

const testing = std.testing;

test "the token spring equals the design's signature spring (drift catcher)" {
    const scale = 1000.0;
    try testing.expectApproxEqAbs(design_signature_spring[0], @as(f32, @floatFromInt(theme.ease_spring_x1)) / scale, 1e-6);
    try testing.expectApproxEqAbs(design_signature_spring[1], @as(f32, @floatFromInt(theme.ease_spring_y1)) / scale, 1e-6);
    try testing.expectApproxEqAbs(design_signature_spring[2], @as(f32, @floatFromInt(theme.ease_spring_x2)) / scale, 1e-6);
    try testing.expectApproxEqAbs(design_signature_spring[3], @as(f32, @floatFromInt(theme.ease_spring_y2)) / scale, 1e-6);
}

test "the spring interpolator matches the design curve's shape, sampled at N points" {
    // CP3(b): sample the implemented spring and the design curve at N points across the
    // unit interval and require they agree within tolerance. A curve with the right
    // endpoints but the wrong middle — smooth but not the design's spring — fails here.
    var i: usize = 0;
    while (i < sample_points) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_points - 1));
        const implemented = interpolate.spring(t);
        const design = interpolate.cubicBezier(
            design_signature_spring[0],
            design_signature_spring[1],
            design_signature_spring[2],
            design_signature_spring[3],
            t,
        );
        try testing.expectApproxEqAbs(design, implemented, shape_tolerance);
    }
}

test "a wrong-but-smooth spring is rejected by the sampled check" {
    // Guard the gate itself: a curve with the correct endpoints but a different middle
    // must fall outside tolerance somewhere, or the check is not catching shape.
    var max_gap: f32 = 0;
    var i: usize = 0;
    while (i < sample_points) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_points - 1));
        const design = interpolate.cubicBezier(0.2, 0.9, 0.25, 1.1, t);
        const wrong = interpolate.cubicBezier(0.42, 0.0, 0.58, 1.0, t); // a plain ease-in-out
        max_gap = @max(max_gap, @abs(design - wrong));
    }
    try testing.expect(max_gap > shape_tolerance); // the shapes genuinely differ
}
