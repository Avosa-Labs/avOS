//! Validating a material's properties before it is used to shade a surface, so an
//! out-of-range value is caught rather than producing an impossible or garbage result.
//!
//! A material describes how a surface looks — how opaque it is, how rough or smooth, how
//! it blends with what is behind it. Each of these is a value with a defined range, and a
//! value outside its range is not a stylistic choice, it is a bug: an opacity above one is
//! meaningless, a negative roughness has no physical sense, and a blend mode that is not a
//! defined mode has no shader to run. A renderer that shades with an invalid material
//! produces garbage — wrong colours, impossible transparency — or crashes reaching for a
//! shader that does not exist. So a material is validated before it shades anything: its
//! scalar properties must lie in their unit ranges and its blend mode must be one that
//! exists. A material that passes is safe to shade with; one that fails is rejected where
//! the mistake was made, not rendered into a broken frame.
//!
//! This module shades nothing. It decides whether a material's properties are all in
//! range, as a pure function over the material.

const std = @import("std");

/// How a material combines with what is behind it. A closed set — a mode outside it has
/// no shader.
pub const BlendMode = enum {
    /// Fully replaces what is behind, weighted by alpha.
    normal,
    /// Adds to what is behind: for glows and light.
    additive,
    /// Multiplies with what is behind: for shadows and tint.
    multiply,
};

/// A material's shading properties.
pub const Material = struct {
    /// How opaque, 0 (invisible) to 1 (solid).
    opacity: f32,
    /// How rough, 0 (mirror) to 1 (fully diffuse).
    roughness: f32,
    /// How metallic, 0 (dielectric) to 1 (metal).
    metallic: f32,
    blend: BlendMode,

    /// Whether every property is in its valid range.
    ///
    /// The three scalar properties must each lie in the closed unit interval — a value
    /// outside it is physically meaningless and would shade to garbage. The blend mode,
    /// being an enum, is one of the defined modes by construction. A material for which
    /// this holds is safe to shade with.
    pub fn valid(material: Material) bool {
        return inUnit(material.opacity) and inUnit(material.roughness) and inUnit(material.metallic);
    }
};

/// Whether a scalar is within the closed unit interval, and not NaN.
fn inUnit(value: f32) bool {
    return !std.math.isNan(value) and value >= 0.0 and value <= 1.0;
}

test "a well-formed material is valid" {
    const material: Material = .{ .opacity = 1.0, .roughness = 0.5, .metallic = 0.0, .blend = .normal };
    try std.testing.expect(material.valid());
}

test "an opacity above one is invalid" {
    const material: Material = .{ .opacity = 1.5, .roughness = 0.5, .metallic = 0.0, .blend = .normal };
    try std.testing.expect(!material.valid());
}

test "a negative roughness is invalid" {
    const material: Material = .{ .opacity = 1.0, .roughness = -0.1, .metallic = 0.0, .blend = .normal };
    try std.testing.expect(!material.valid());
}

test "a NaN property is invalid" {
    const material: Material = .{ .opacity = std.math.nan(f32), .roughness = 0.5, .metallic = 0.0, .blend = .normal };
    try std.testing.expect(!material.valid());
}

test "the unit bounds are inclusive" {
    const at_zero: Material = .{ .opacity = 0.0, .roughness = 0.0, .metallic = 0.0, .blend = .additive };
    const at_one: Material = .{ .opacity = 1.0, .roughness = 1.0, .metallic = 1.0, .blend = .multiply };
    try std.testing.expect(at_zero.valid());
    try std.testing.expect(at_one.valid());
}

test "a valid material has every scalar in the unit interval, swept" {
    // The in-range property: whenever a material validates, each scalar is within [0,1].
    const values = [_]f32{ -0.5, 0.0, 0.5, 1.0, 1.5 };
    for (values) |opacity| {
        for (values) |roughness| {
            const material: Material = .{ .opacity = opacity, .roughness = roughness, .metallic = 0.5, .blend = .normal };
            if (material.valid()) {
                try std.testing.expect(inUnit(opacity) and inUnit(roughness));
            }
        }
    }
}
