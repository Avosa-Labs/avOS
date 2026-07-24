//! Deciding whether an animation plays and for how long, honouring a person's reduced-
//! motion preference, so motion that would make them sick is suppressed while motion they
//! need to follow the interface is kept.
//!
//! Animation is not free for everyone. For people with vestibular disorders, large sliding
//! and parallax motion causes real nausea and disorientation, which is why the platform
//! offers a reduce-motion preference. Honouring it well is a distinction, not a switch:
//! decorative motion — a bouncing icon, a parallax background — is suppressed entirely,
//! because it adds nothing a person needs and is exactly what triggers discomfort; but
//! essential motion — the transition that shows where a dismissed screen went, the spinner
//! that says the system is working — is not removed, because without it a person loses the
//! thread of what the interface is doing. Under reduce-motion, essential motion is replaced
//! by a quick, simple fade rather than a large movement. So the decision depends on both
//! the person's preference and whether the motion carries meaning, and the interface stays
//! both comfortable and comprehensible.
//!
//! This module animates nothing. It decides whether a motion plays and its duration, from
//! the person's preference and the motion's role, as pure functions.

const std = @import("std");

/// What an animation is for, which decides whether reduce-motion may suppress it.
pub const Role = enum {
    /// Decorative: adds polish but carries no meaning. Suppressed entirely under
    /// reduce-motion.
    decorative,
    /// Essential: conveys where something went or that work is happening. Kept, but
    /// simplified to a fade under reduce-motion.
    essential,
};

/// The person's motion preference.
pub const Preference = enum { full_motion, reduced_motion };

/// How a motion should play.
pub const Playback = union(enum) {
    /// Play the full animation for this many milliseconds.
    animate: u32,
    /// Play a simple fade for this many milliseconds instead of movement.
    fade: u32,
    /// Do not animate; apply the end state instantly.
    none,

    pub fn moves(playback: Playback) bool {
        return playback == .animate;
    }
};

/// The duration a simplified fade uses under reduce-motion. Short, because its job is
/// only to avoid a jarring instant cut, not to be noticed.
pub const reduced_fade_ms: u32 = 100;

/// Decides how a motion plays, given the person's preference and the motion's role.
///
/// Under full motion, every animation plays for its requested duration. Under reduced
/// motion, decorative animation is dropped to nothing — it carries no meaning and is what
/// causes discomfort — while essential animation is replaced by a quick fade, so a person
/// still sees that something changed without the large movement that triggers nausea.
pub fn resolve(role: Role, preference: Preference, requested_ms: u32) Playback {
    if (preference == .full_motion) return .{ .animate = requested_ms };
    return switch (role) {
        .decorative => .none,
        .essential => .{ .fade = reduced_fade_ms },
    };
}

test "full motion plays every animation as requested" {
    try std.testing.expectEqual(Playback{ .animate = 300 }, resolve(.decorative, .full_motion, 300));
    try std.testing.expectEqual(Playback{ .animate = 300 }, resolve(.essential, .full_motion, 300));
}

test "reduced motion suppresses decorative animation entirely" {
    try std.testing.expectEqual(Playback.none, resolve(.decorative, .reduced_motion, 300));
}

test "reduced motion keeps essential motion as a fade" {
    try std.testing.expectEqual(Playback{ .fade = reduced_fade_ms }, resolve(.essential, .reduced_motion, 300));
}

test "no large movement plays under reduced motion, swept" {
    // The comfort property: under reduced motion, nothing returns an `animate` (large
    // movement) playback, whatever the role or duration.
    const durations = [_]u32{ 0, 100, 300, 1000 };
    for ([_]Role{ .decorative, .essential }) |role| {
        for (durations) |ms| {
            const playback = resolve(role, .reduced_motion, ms);
            try std.testing.expect(!playback.moves());
        }
    }
}

test "essential motion is never fully removed, swept" {
    // The comprehension property: essential motion always produces something visible — a
    // full animation or a fade — never nothing, so a person never loses the thread.
    for ([_]Preference{ .full_motion, .reduced_motion }) |preference| {
        const playback = resolve(.essential, preference, 300);
        try std.testing.expect(playback != .none);
    }
}
