//! Deciding whether the screen may be captured and which surfaces are blacked out
//! of the capture, so a screenshot or a screen recording cannot lift a password or
//! protected content off the display.
//!
//! Capturing the screen — a screenshot, a recording, casting to another display — is
//! useful and is also a way to exfiltrate whatever is on screen, so it is gated at
//! two levels. The capture itself needs the person's agreement: an app cannot record
//! the screen silently in the background, because a running recorder is a running
//! camera pointed at everything the person does. And even an agreed capture excludes
//! the surfaces that must never be copied — a password field, DRM-protected video, a
//! banking view marked secure — which are blacked out of the frame rather than
//! included, so the capture a person meant to take of one thing does not quietly
//! carry another. What is protected is decided by the surface, not the capturer, so
//! marking a surface secure keeps it out of every capture, wanted or not.
//!
//! This module captures no pixels. It decides whether a capture may proceed given
//! consent, and whether a given surface is included or blacked out, as pure functions
//! over the capture's authorization and each surface's protection.

const std = @import("std");

/// How a capture was authorized.
pub const Consent = enum {
    /// The person agreed to this capture — tapped the shutter, started the recording,
    /// approved the cast.
    granted,
    /// No agreement. The capture must not proceed at all.
    none,
};

/// How protected a surface is against being captured.
pub const Protection = enum {
    /// Ordinary content. Included in a captured frame.
    ordinary,
    /// Secure content: a password field, DRM video, a surface a service marked
    /// no-capture. Blacked out of every capture.
    secure,

    fn isSecure(protection: Protection) bool {
        return protection == .secure;
    }
};

/// Whether a capture may proceed at all.
///
/// Only with the person's consent. A capture without it does not run, so nothing
/// records the screen behind the person's back.
pub fn captureAllowed(consent: Consent) bool {
    return consent == .granted;
}

/// Whether a surface appears in a captured frame, or is blacked out.
///
/// A secure surface is never included, whatever the consent — the person may capture
/// the screen, but the password field within it is blacked out — because the
/// protection belongs to the surface, not to the capture. Ordinary surfaces are
/// included in an allowed capture.
pub fn surfaceIncluded(consent: Consent, protection: Protection) bool {
    if (!captureAllowed(consent)) return false;
    return !protection.isSecure();
}

test "a capture proceeds only with consent" {
    try std.testing.expect(captureAllowed(.granted));
    try std.testing.expect(!captureAllowed(.none));
}

test "an ordinary surface is included in a consented capture" {
    try std.testing.expect(surfaceIncluded(.granted, .ordinary));
}

test "a secure surface is blacked out even in a consented capture" {
    try std.testing.expect(!surfaceIncluded(.granted, .secure));
}

test "nothing is captured without consent" {
    try std.testing.expect(!surfaceIncluded(.none, .ordinary));
    try std.testing.expect(!surfaceIncluded(.none, .secure));
}

test "a secure surface is never included, whatever the consent, swept" {
    // The surface-protection property: a secure surface is out of every capture,
    // consented or not.
    for ([_]Consent{ .granted, .none }) |consent| {
        try std.testing.expect(!surfaceIncluded(consent, .secure));
    }
}

test "no surface is ever captured without consent, swept" {
    for ([_]Protection{ .ordinary, .secure }) |protection| {
        try std.testing.expect(!surfaceIncluded(.none, protection));
    }
}
