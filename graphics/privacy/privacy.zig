//! Deciding whether a composited region is protected, propagating a surface's secure
//! marking through composition, so protected content stays protected wherever it ends up
//! on screen.
//!
//! Some surfaces are marked secure — a DRM-protected video, a password field, a banking
//! view a service flagged — meaning their pixels must never be read back off the screen.
//! Composition combines surfaces into regions of the final image, and the secure marking
//! has to travel with the pixels or the protection leaks: if a secure surface is composed
//! into a region and the region loses the marking, a readback of that region captures the
//! secure content the marking was supposed to guard. So security propagates conservatively
//! through composition — a composited region is secure if any secure surface contributes
//! to it — and once a region is secure it stays secure regardless of what else is composed
//! over or under it. The result is that protection is a property of the pixels, following
//! them through every stage of composition, so there is no arrangement of surfaces that
//! strips it.
//!
//! This module composites nothing. It decides whether a region is secure given the
//! surfaces contributing to it, as a pure function so the propagation rule holds in one
//! place.

const std = @import("std");

/// A surface contributing to a composited region.
pub const Surface = struct {
    /// Whether this surface is marked secure — its pixels must not be read back.
    secure: bool,
};

/// Whether a composited region is secure, given the surfaces contributing to it.
///
/// The region is secure if any contributing surface is secure. Security joins upward: a
/// single secure contributor makes the whole region secure, because a readback of the
/// region would otherwise capture that contributor's protected pixels. There is no
/// arrangement — nothing composed over or under — that removes the marking once a secure
/// surface is present.
pub fn regionSecure(contributors: []const Surface) bool {
    for (contributors) |surface| {
        if (surface.secure) return true;
    }
    return false;
}

/// Whether composing an additional surface onto an already-composited region leaves it
/// secure. Monotone: a region that is already secure stays secure, and composing a secure
/// surface makes a region secure.
pub fn afterCompose(region_secure: bool, added: Surface) bool {
    return region_secure or added.secure;
}

test "a region with no secure surface is not secure" {
    const surfaces = [_]Surface{ .{ .secure = false }, .{ .secure = false } };
    try std.testing.expect(!regionSecure(&surfaces));
}

test "a region with any secure surface is secure" {
    const surfaces = [_]Surface{ .{ .secure = false }, .{ .secure = true }, .{ .secure = false } };
    try std.testing.expect(regionSecure(&surfaces));
}

test "an empty region is not secure" {
    try std.testing.expect(!regionSecure(&.{}));
}

test "composing a secure surface makes a region secure" {
    try std.testing.expect(afterCompose(false, .{ .secure = true }));
}

test "a secure region stays secure whatever is composed onto it" {
    // Composing a non-secure surface onto a secure region does not strip the marking.
    try std.testing.expect(afterCompose(true, .{ .secure = false }));
    try std.testing.expect(afterCompose(true, .{ .secure = true }));
}

test "security propagation is monotone, swept" {
    // The no-strip property: once secure, always secure; and a secure addition always
    // secures.
    for ([_]bool{ false, true }) |region| {
        for ([_]bool{ false, true }) |added_secure| {
            const result = afterCompose(region, .{ .secure = added_secure });
            // The result is at least as secure as the region was and as the addition.
            if (region or added_secure) try std.testing.expect(result);
        }
    }
}

test "a region is secure exactly when some contributor is, swept" {
    const configs = [_][]const Surface{
        &.{},
        &.{.{ .secure = false }},
        &.{.{ .secure = true }},
        &.{ .{ .secure = false }, .{ .secure = true } },
    };
    for (configs) |contributors| {
        var any_secure = false;
        for (contributors) |surface| {
            if (surface.secure) any_secure = true;
        }
        try std.testing.expectEqual(any_secure, regionSecure(contributors));
    }
}
