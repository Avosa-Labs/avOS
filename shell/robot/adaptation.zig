//! Deciding what a robot endpoint exposes, so an autonomous machine can offer its movement and
//! sensing capabilities to the session without exposing the person's messages or private data.
//!
//! A robot is an endpoint with a body: it can move, actuate, and sense the physical world, and those
//! physical capabilities are the whole reason to bring a session onto it. But a machine that drives
//! around a space, that others may be near, that could be tampered with, is the last place the
//! person's private communications should live. So the robot form factor exposes its device
//! capabilities — movement, actuation, environmental sensing — and is denied the personal-data
//! capabilities a private handset holds: messages, mail, and the rest stay off the robot. The
//! platform's example states it directly: a robot may expose movement without messages. This is the
//! device-not-identity rule at its sharpest — the robot contributes what a robot uniquely can do to
//! the person's environment, and gains none of the private authority that environment carries
//! elsewhere. Exposing physical capability while withholding personal data is what lets a robot be a
//! genuine participant in a session without becoming a mobile leak of the person's private life.
//!
//! This module moves nothing. It decides whether the robot may expose a given capability, as a pure
//! function.

const std = @import("std");

/// A capability an endpoint might expose to the session.
pub const Capability = enum {
    /// Physical movement and navigation.
    movement,
    /// Actuation — manipulating the physical world.
    actuation,
    /// Environmental sensing — cameras, depth, proximity for navigation.
    sensing,
    /// The person's messages.
    messages,
    /// The person's mail.
    mail,
};

/// Whether the capability is a physical one belonging to the robot's body.
fn isPhysical(capability: Capability) bool {
    return switch (capability) {
        .movement, .actuation, .sensing => true,
        .messages, .mail => false,
    };
}

/// Whether the robot form factor may expose a capability.
///
/// It exposes its physical capabilities — movement, actuation, sensing — and never the person's
/// personal-data capabilities. So the robot brings its body to the session and leaves the person's
/// private communications out of reach.
pub fn mayExpose(capability: Capability) bool {
    return isPhysical(capability);
}

test "the robot exposes its physical capabilities" {
    try std.testing.expect(mayExpose(.movement));
    try std.testing.expect(mayExpose(.actuation));
    try std.testing.expect(mayExpose(.sensing));
}

test "the robot does not expose personal data" {
    try std.testing.expect(!mayExpose(.messages));
    try std.testing.expect(!mayExpose(.mail));
}

test "every exposed capability is physical, swept" {
    // The movement-without-messages property: the robot exposes only its body's capabilities.
    for (std.enums.values(Capability)) |capability| {
        if (mayExpose(capability)) {
            try std.testing.expect(isPhysical(capability));
        }
    }
}
