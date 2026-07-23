//! Deciding whether input to a sensitive window can be trusted when another window
//! overlays it, so a transparent overlay cannot trick a person into approving what
//! they cannot see.
//!
//! A person approves something — a permission, a payment, a pairing — by looking at
//! a prompt and tapping it. That trust rests on an assumption the window system must
//! protect: what the person sees is what receives the tap. Tapjacking breaks the
//! assumption. A hostile app draws a transparent or decoy window over the real
//! prompt; the person, seeing the decoy, taps what they think is a harmless button,
//! and the tap lands on the "Allow" beneath. So input to a security-sensitive window
//! is trusted only when nothing untrusted sits over the region being touched. A
//! system-drawn overlay — a status bar, an incoming-call banner — is trusted and
//! does not taint the input; an ordinary app's overlay does, and while it covers the
//! prompt the person's taps on that prompt cannot be believed to be informed.
//!
//! This module composites nothing. It decides whether a tap on a sensitive window is
//! trustworthy given what overlays it, as a pure function over the overlay set, so
//! the tapjacking defence lives at one gate rather than in each prompt.

const std = @import("std");

/// Who drew an overlay window, which sets whether it can be trusted not to deceive.
pub const Origin = enum {
    /// Drawn by the system: a status bar, a call banner, an accessibility cursor.
    /// Trusted; it does not taint input to what it covers.
    system,
    /// Drawn by an ordinary application. Untrusted over a sensitive window, because
    /// it could be the decoy in a tapjack.
    application,

    fn isTrusted(origin: Origin) bool {
        return origin == .system;
    }
};

/// An overlay window sitting above the sensitive target.
pub const Overlay = struct {
    origin: Origin,
    /// Whether the overlay actually covers the region of the target being touched.
    /// An overlay elsewhere on screen does not affect this tap.
    covers_touch_point: bool,
    /// Whether the overlay is visually transparent enough that the person may not
    /// realise it is there. Opaque system chrome the person can see is not a
    /// deception; a transparent app layer is.
    passes_through_visually: bool,
};

/// Whether an overlay taints input to the sensitive window beneath it.
///
/// Only an untrusted overlay that both covers the touched region and is visually
/// transparent is a tapjacking risk: it is over the tap, and the person cannot see
/// that it is. A system overlay is trusted, an overlay that does not cover the tap is
/// irrelevant to it, and an opaque app overlay the person can plainly see is not a
/// hidden deception.
pub fn taints(overlay: Overlay) bool {
    if (overlay.origin.isTrusted()) return false;
    if (!overlay.covers_touch_point) return false;
    return overlay.passes_through_visually;
}

/// Whether a tap on a sensitive window may be trusted, given everything overlaying
/// it.
///
/// The tap is trusted only if no overlay taints it. A single tainting overlay is
/// enough to reject the input, because the person may have been deceived about what
/// they were tapping, and a security-sensitive approval must never be granted on a
/// tap that might have been misdirected.
pub fn inputTrusted(overlays: []const Overlay) bool {
    for (overlays) |overlay| {
        if (taints(overlay)) return false;
    }
    return true;
}

test "a tap with no overlays is trusted" {
    try std.testing.expect(inputTrusted(&.{}));
}

test "a transparent app overlay over the tap taints it" {
    const overlays = [_]Overlay{.{ .origin = .application, .covers_touch_point = true, .passes_through_visually = true }};
    try std.testing.expect(!inputTrusted(&overlays));
}

test "a system overlay does not taint the input" {
    // A call banner over the prompt is visible and trusted; the person is not
    // deceived by it.
    const overlays = [_]Overlay{.{ .origin = .system, .covers_touch_point = true, .passes_through_visually = true }};
    try std.testing.expect(inputTrusted(&overlays));
}

test "an app overlay that does not cover the tap is irrelevant" {
    const overlays = [_]Overlay{.{ .origin = .application, .covers_touch_point = false, .passes_through_visually = true }};
    try std.testing.expect(inputTrusted(&overlays));
}

test "an opaque app overlay the person can see is not a deception" {
    // Covers the tap but is visible; the person knows something is there and is not
    // being tricked into tapping through it.
    const overlays = [_]Overlay{.{ .origin = .application, .covers_touch_point = true, .passes_through_visually = false }};
    try std.testing.expect(inputTrusted(&overlays));
}

test "one tainting overlay among trusted ones rejects the input" {
    const overlays = [_]Overlay{
        .{ .origin = .system, .covers_touch_point = true, .passes_through_visually = true },
        .{ .origin = .application, .covers_touch_point = true, .passes_through_visually = true }, // the tapjack
        .{ .origin = .application, .covers_touch_point = false, .passes_through_visually = true },
    };
    try std.testing.expect(!inputTrusted(&overlays));
}

test "input is trusted only when no overlay is a hidden app layer over the tap, swept" {
    // The tapjacking property: across every overlay shape, input is untrusted
    // exactly when some untrusted, transparent overlay covers the tap.
    for ([_]Origin{ .system, .application }) |origin| {
        for ([_]bool{ false, true }) |covers| {
            for ([_]bool{ false, true }) |transparent| {
                const overlay: Overlay = .{ .origin = origin, .covers_touch_point = covers, .passes_through_visually = transparent };
                const trusted = inputTrusted(&.{overlay});
                const should_taint = origin == .application and covers and transparent;
                try std.testing.expectEqual(!should_taint, trusted);
            }
        }
    }
}
