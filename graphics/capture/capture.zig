//! Deciding whether a surface's pixels may appear in a framebuffer readback, so a
//! screenshot, recording, or thumbnail never captures a surface marked secure.
//!
//! A readback copies pixels off the screen — a screenshot, a screen recording, a cast to
//! another display, a thumbnail for the app switcher. Each is a way protected content
//! could escape, and the graphics layer is the last place to stop it, because once the
//! pixels are in a readback buffer the protection is gone. So a readback is composed with
//! a rule: a surface marked secure is excluded from it — blacked out, never copied —
//! regardless of the kind of readback, because the marking is a property of the surface,
//! not a preference of whoever is capturing. Ordinary surfaces are included. This is
//! deliberately the same answer for every readback kind: a thumbnail for the task switcher
//! is as capable of leaking a password field as a screen recording is, so a secure surface
//! is excluded from the harmless-looking captures too. Protection is uniform, or it is not
//! protection.
//!
//! This module copies no pixels. It decides whether a surface is included in or excluded
//! from a readback, as a pure function over the surface's secure marking.

const std = @import("std");

/// The kind of framebuffer readback being performed. Listed to make explicit that the
/// decision is the same for all of them.
pub const Kind = enum {
    /// A single screenshot.
    screenshot,
    /// A continuous screen recording.
    recording,
    /// A cast or mirror to another display.
    cast,
    /// A thumbnail for the task switcher or a preview.
    thumbnail,
};

/// A surface being considered for a readback.
pub const Surface = struct {
    /// Whether the surface is marked secure — its pixels must never be read back.
    secure: bool,
};

/// What happens to a surface in a readback.
pub const Inclusion = enum {
    /// The surface's pixels are copied into the readback.
    include,
    /// The surface is blacked out of the readback; its pixels are never copied.
    exclude,

    pub fn included(inclusion: Inclusion) bool {
        return inclusion == .include;
    }
};

/// Decides whether a surface appears in a readback of a given kind.
///
/// A secure surface is excluded from every kind of readback — the marking is a property
/// of the surface, not of the capture, so a thumbnail is as forbidden as a recording. An
/// ordinary surface is included. The readback kind is accepted but does not change the
/// answer for a secure surface, which is the point: protection is uniform across every way
/// pixels can leave the screen.
pub fn decide(surface: Surface, kind: Kind) Inclusion {
    _ = kind; // the answer is deliberately the same for every readback kind
    return if (surface.secure) .exclude else .include;
}

test "an ordinary surface is included in a screenshot" {
    try std.testing.expectEqual(Inclusion.include, decide(.{ .secure = false }, .screenshot));
}

test "a secure surface is excluded from a screenshot" {
    try std.testing.expectEqual(Inclusion.exclude, decide(.{ .secure = true }, .screenshot));
}

test "a secure surface is excluded from a thumbnail too" {
    // The harmless-looking capture is as forbidden as the obvious one.
    try std.testing.expectEqual(Inclusion.exclude, decide(.{ .secure = true }, .thumbnail));
}

test "a secure surface is excluded from every readback kind, swept" {
    // The uniform-protection property: whatever the readback kind, a secure surface is
    // never included.
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expectEqual(Inclusion.exclude, decide(.{ .secure = true }, kind));
        try std.testing.expect(!decide(.{ .secure = true }, kind).included());
    }
}

test "an ordinary surface is included in every readback kind, swept" {
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(decide(.{ .secure = false }, kind).included());
    }
}
