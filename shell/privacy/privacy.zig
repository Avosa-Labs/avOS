//! Deciding which live sensor-in-use indicators must show and whether the access history is
//! readable while locked, so a person can always tell when they are being sensed.
//!
//! The privacy dashboard answers two different questions, and they resolve in opposite
//! directions. A live indicator — the dot that lights when the camera or microphone is
//! actively capturing — is a warning, not private data, so it must show no matter what,
//! including on a locked device; hiding it would let a capture run unseen, which is the one
//! failure the dashboard exists to prevent. The detailed access history, by contrast, is a
//! record of the person's past activity and the apps they use, so it is private and stays
//! behind the lock, readable only after the person authenticates. So an active capture can
//! never be silenced, while the log that explains it waits for unlock.
//!
//! This module shows nothing. It decides whether an access requires a live indicator and
//! whether the history is visible while locked, as a pure function over the access kind.

const std = @import("std");

/// A kind of sensitive access the dashboard tracks, which decides whether an active use of it
/// must raise a live indicator.
pub const Access = enum {
    /// A live capture stream the person must always be able to see is running.
    camera,
    /// A live capture stream the person must always be able to see is running.
    microphone,
    /// A read of the device's position; surfaced live so background tracking is visible.
    location,
    /// A read of the address book; recorded in history but raises no live indicator.
    contacts,
    /// A read of stored photos; recorded in history but raises no live indicator.
    photos,
};

/// Whether an active use of this access must show a live indicator, even while locked.
///
/// Camera, microphone, and location are ongoing sensing of the physical person, so their use
/// must always be visible — the indicator is a safety warning, and a warning that can be hidden
/// is no warning at all. Reads of stored data like contacts or photos are logged in the history
/// instead of raising a live dot, because they are discrete events, not a running stream the
/// person needs to catch in the moment.
pub fn indicatorRequired(access: Access) bool {
    return switch (access) {
        .camera, .microphone, .location => true,
        .contacts, .photos => false,
    };
}

/// Whether the detailed access history may be read while the device is locked.
///
/// Never. The history is a private record of what was accessed and by whom, so it is gated
/// behind the lock exactly like any other private data; the live indicators, not the log,
/// carry the always-visible warning.
pub fn historyVisibleWhileLocked() bool {
    return false;
}

test "an active camera or microphone always shows an indicator" {
    try std.testing.expect(indicatorRequired(.camera));
    try std.testing.expect(indicatorRequired(.microphone));
}

test "location use is surfaced live" {
    try std.testing.expect(indicatorRequired(.location));
}

test "stored-data reads are logged but raise no live indicator" {
    try std.testing.expect(!indicatorRequired(.contacts));
    try std.testing.expect(!indicatorRequired(.photos));
}

test "the access history is never readable while locked" {
    try std.testing.expect(!historyVisibleWhileLocked());
}

test "every live-capture access raises an indicator that no lock state can suppress, swept" {
    // The capture-visibility property: an active camera, microphone, or location read is
    // always indicated, independent of whether the history behind it is readable.
    for (std.enums.values(Access)) |access| {
        switch (access) {
            .camera, .microphone, .location => try std.testing.expect(indicatorRequired(access)),
            else => {},
        }
    }
    try std.testing.expect(!historyVisibleWhileLocked());
}
