//! Deciding what a presentation frame for an endpoint may contain, so what is drawn on a surface
//! never includes state that surface is not trusted to show.
//!
//! Presenting an instance on an endpoint means composing a frame — the concrete thing rendered on
//! that screen — from the instance's state. The screen is a physical place with its own exposure: a
//! phone in a pocket, a laptop in a café, a display on a meeting-room wall that a dozen people can
//! read. So a field's inclusion in a frame turns on whether the endpoint is trusted to show it. A
//! field marked sensitive — a message body, a balance, a secret — is included only for an endpoint
//! trusted with sensitive content; on any other surface it is masked, present as a placeholder the
//! person can choose to reveal but not rendered by default. Non-sensitive fields render everywhere
//! that may present. The frame is the last gate before pixels, and getting it right is what stops the
//! same instance from spilling a private message onto a shared wall display just because that display
//! is a valid endpoint. Composing each frame against the endpoint's trust keeps presentation matched
//! to the place it happens.
//!
//! This module draws nothing. It decides whether a field is rendered in an endpoint's presentation
//! frame, from the field's sensitivity and the endpoint's trust, as a pure function.

const std = @import("std");

/// How exposed a field's content is if shown on the wrong surface.
pub const Sensitivity = enum {
    /// Ordinary content, safe to render on any presenting surface.
    ordinary,
    /// Private content — message bodies, balances, secrets — masked unless the surface is trusted.
    sensitive,
};

/// How much a presenting endpoint is trusted with content.
pub const Trust = enum {
    /// A surface whose surroundings are not controlled; sensitive content is masked.
    shared_surface,
    /// A surface trusted to show sensitive content — the person's own private device.
    private_surface,
};

/// How a field appears in a frame.
pub const Render = enum {
    /// The field's content is drawn.
    shown,
    /// The field is masked — a placeholder the person may reveal, but not the content.
    masked,
};

/// Decides how a field is rendered in an endpoint's presentation frame.
///
/// An ordinary field is shown on any presenting surface. A sensitive field is shown only on a private
/// surface and masked on a shared one, so composing a frame for a shared display never draws private
/// content onto it by default.
pub fn render(sensitivity: Sensitivity, trust: Trust) Render {
    return switch (sensitivity) {
        .ordinary => .shown,
        .sensitive => if (trust == .private_surface) .shown else .masked,
    };
}

test "ordinary content renders on any surface" {
    try std.testing.expectEqual(Render.shown, render(.ordinary, .shared_surface));
    try std.testing.expectEqual(Render.shown, render(.ordinary, .private_surface));
}

test "sensitive content is masked on a shared surface" {
    try std.testing.expectEqual(Render.masked, render(.sensitive, .shared_surface));
}

test "sensitive content shows on a private surface" {
    try std.testing.expectEqual(Render.shown, render(.sensitive, .private_surface));
}

test "sensitive content is only ever shown on a private surface, swept" {
    // The frame-safety property: whenever sensitive content is drawn, the surface was private.
    for ([_]Trust{ .shared_surface, .private_surface }) |trust| {
        if (render(.sensitive, trust) == .shown) {
            try std.testing.expectEqual(Trust.private_surface, trust);
        }
    }
}
