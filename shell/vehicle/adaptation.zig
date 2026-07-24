//! Deciding what a vehicle surface may present, so a session in a moving car suppresses anything that
//! demands the driver's eyes and offers only glanceable or spoken interaction.
//!
//! A vehicle is a surface whose safety context changes with motion. Parked, it is much like any
//! display. Moving, it is in front of a person who must be watching the road, and a surface that
//! demands visual attention there is not a feature but a hazard. So the vehicle form factor gates
//! interaction on motion: while the vehicle is in motion, visual-attention-demanding surfaces are
//! suppressed and interaction is reduced to what can be done glanceably or by voice, with consequential
//! confirmation handled through speech rather than a screen the driver would have to read. At rest the
//! restriction lifts. This is a form factor whose defining rule is a suppression, not an expansion:
//! the session still moves onto the vehicle, but the vehicle refuses to present in a way that would
//! pull the driver's gaze from the road. Suppressing visual interaction under motion is what lets the
//! platform put a person's environment in their car without the car's screen competing with driving.
//!
//! This module drives nothing. It decides whether a surface of a given attention demand may present
//! while the vehicle is in motion, as a pure function.

const std = @import("std");

/// How much visual attention a surface demands to use.
pub const AttentionDemand = enum {
    /// Usable at a glance or entirely by voice — a turn prompt, a spoken confirmation.
    glanceable,
    /// Requires sustained reading or precise touch — a list, a form, dense text.
    visual,
};

/// Whether a surface may present given the vehicle's motion.
///
/// At rest, any surface may present. In motion, only glanceable or voice-first surfaces may; a
/// visual-attention-demanding surface is suppressed, so nothing that would require the driver to read
/// or aim at the screen is shown while the vehicle is moving.
pub fn mayPresent(demand: AttentionDemand, in_motion: bool) bool {
    if (!in_motion) return true;
    return demand == .glanceable;
}

test "at rest, any surface may present" {
    try std.testing.expect(mayPresent(.glanceable, false));
    try std.testing.expect(mayPresent(.visual, false));
}

test "in motion, only glanceable surfaces present" {
    try std.testing.expect(mayPresent(.glanceable, true));
    try std.testing.expect(!mayPresent(.visual, true));
}

test "no visual-attention surface presents while moving, swept" {
    // The driver-safety property: any surface presented in motion is glanceable.
    for ([_]AttentionDemand{ .glanceable, .visual }) |demand| {
        if (mayPresent(demand, true)) {
            try std.testing.expectEqual(AttentionDemand.glanceable, demand);
        }
    }
}
