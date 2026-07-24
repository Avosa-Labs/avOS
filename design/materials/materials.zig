//! Resolving a semantic surface material into an elevation and a background treatment, so
//! surfaces read as a consistent hierarchy rather than each picking its own look.
//!
//! Interfaces use materials to say how a surface relates to what is around it — a base layer
//! the content sits on, a raised card, a floating menu, a modal that dims everything behind.
//! Each of these carries two facts a surface should not invent for itself: an elevation, how
//! far it reads as lifted above the layer below, and a background treatment, whether it is
//! opaque, translucent over what is behind, or a dimming scrim. If every surface chose its
//! own shadow depth and blur, the interface would have no consistent sense of depth and a
//! card on one screen would look raised while the same card elsewhere looked flat. So a
//! material is semantic: a fixed role maps to one elevation and one treatment, and the
//! mapping is monotone — a role that is conceptually higher in the stack never resolves to a
//! lower elevation than one beneath it. Surfaces ask for a role and get a consistent depth,
//! so the whole interface shares one language of layering.
//!
//! This module renders no surface. It resolves a material role into its elevation and
//! background treatment, as pure functions over a fixed table.

const std = @import("std");

/// A semantic surface material, ordered from the base layer upward.
pub const Material = enum(u8) {
    /// The base layer content sits on.
    base = 0,
    /// A raised card or grouped surface.
    raised = 1,
    /// A floating element: a menu, a popover.
    floating = 2,
    /// A modal surface that sits above everything, over a dimming scrim.
    modal = 3,

    fn rank(material: Material) u8 {
        return @intFromEnum(material);
    }
};

/// How a surface's background is treated.
pub const Treatment = enum {
    /// Opaque: fully hides what is behind.
    opaque_fill,
    /// Translucent: blurs and tints what is behind.
    translucent,
    /// A dimming scrim over the content behind a modal.
    scrim,
};

/// The elevation, in points, a material reads as lifted above the base. Higher materials
/// cast the impression of being further forward.
pub fn elevation(material: Material) u32 {
    return switch (material) {
        .base => 0,
        .raised => 2,
        .floating => 8,
        .modal => 16,
    };
}

/// The background treatment a material uses.
pub fn treatment(material: Material) Treatment {
    return switch (material) {
        .base => .opaque_fill,
        .raised => .opaque_fill,
        .floating => .translucent,
        .modal => .scrim,
    };
}

test "the base material sits at zero elevation" {
    try std.testing.expectEqual(@as(u32, 0), elevation(.base));
    try std.testing.expectEqual(Treatment.opaque_fill, treatment(.base));
}

test "a modal is the highest elevation over a scrim" {
    try std.testing.expectEqual(@as(u32, 16), elevation(.modal));
    try std.testing.expectEqual(Treatment.scrim, treatment(.modal));
}

test "a floating surface is translucent" {
    try std.testing.expectEqual(Treatment.translucent, treatment(.floating));
}

test "elevation is monotone in the material's rank, swept" {
    // The consistent-hierarchy property: a higher material never has a lower elevation than
    // a lower one.
    const order = [_]Material{ .base, .raised, .floating, .modal };
    var previous: u32 = 0;
    for (order) |material| {
        const e = elevation(material);
        try std.testing.expect(e >= previous);
        previous = e;
    }
}

test "each material resolves to exactly one elevation and treatment" {
    // Determinism: resolving the same material twice gives the same result.
    for (std.enums.values(Material)) |material| {
        try std.testing.expectEqual(elevation(material), elevation(material));
        try std.testing.expectEqual(treatment(material), treatment(material));
    }
}
