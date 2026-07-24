//! Deciding what a locked device lets a person reach, so the lock screen is convenient
//! without becoming a way past the lock.
//!
//! The lock screen is a security boundary with a usability problem: a locked device should
//! reveal nothing private and permit nothing consequential, yet a lock that blocks even the
//! camera and an emergency call is a lock people disable. The line is drawn per surface by
//! what it exposes. A few things are safe and important enough to reach without unlocking —
//! placing an emergency call, the camera, glanceable non-private information like the time —
//! because the harm of blocking them outweighs the little they expose. Everything that shows
//! private content or performs a real action stays behind the lock, reachable only after the
//! person authenticates. And the sensitivity of a notification decides whether its content
//! shows on the lock screen or only that something arrived, so a message preview does not
//! sit readable on a table. So the lock screen is a small allowlist of safe surfaces over a
//! default of deny, which is what keeps it both usable and a real lock.
//!
//! This module unlocks nothing. It decides whether a surface is reachable on a locked
//! device, from what the surface exposes, as a pure function.

const std = @import("std");

/// What a surface exposes, which decides whether it is reachable while locked.
pub const Exposure = enum {
    /// An emergency affordance: an emergency call, medical ID. Always reachable, because
    /// blocking it could cost a life.
    emergency,
    /// Glanceable, non-private information: the time, the weather, that a notification
    /// arrived without its content. Reachable while locked.
    glanceable,
    /// The camera and similarly safe capture that creates but does not reveal existing
    /// private data. Reachable while locked by convention.
    safe_capture,
    /// Private content: messages, photos, the home screen, app content. Hidden until
    /// unlocked.
    private,
    /// A consequential action: sending, paying, changing settings. Blocked until unlocked.
    consequential,
};

/// Whether a surface is reachable given the device's lock state.
///
/// While unlocked, everything is reachable. While locked, only the small set of safe
/// exposures — emergency, glanceable, and safe capture — is reachable; private content and
/// consequential actions are blocked, because they would either reveal private data or take
/// a real action that the lock exists to prevent. The default for anything not on the safe
/// list is to deny.
pub fn reachable(exposure: Exposure, locked: bool) bool {
    if (!locked) return true;
    return switch (exposure) {
        .emergency, .glanceable, .safe_capture => true,
        .private, .consequential => false,
    };
}

test "everything is reachable when unlocked" {
    for (std.enums.values(Exposure)) |exposure| {
        try std.testing.expect(reachable(exposure, false));
    }
}

test "emergency is reachable while locked" {
    try std.testing.expect(reachable(.emergency, true));
}

test "glanceable info and the camera are reachable while locked" {
    try std.testing.expect(reachable(.glanceable, true));
    try std.testing.expect(reachable(.safe_capture, true));
}

test "private content is hidden while locked" {
    try std.testing.expect(!reachable(.private, true));
}

test "a consequential action is blocked while locked" {
    try std.testing.expect(!reachable(.consequential, true));
}

test "a locked device reveals no private content and permits no consequential action, swept" {
    // The lock property: while locked, private and consequential surfaces are never
    // reachable, whatever else is.
    for (std.enums.values(Exposure)) |exposure| {
        if (reachable(exposure, true)) {
            try std.testing.expect(exposure != .private and exposure != .consequential);
        }
    }
}
