//! Deciding whether a quick control may be toggled from a locked device, so the handy
//! toggles work at a glance without opening a hole in the lock.
//!
//! Quick controls — the toggles a person swipes to: flashlight, airplane mode, brightness,
//! and also shortcuts into private things like the wallet or home controls — are meant to be
//! one gesture away. On a locked device that convenience meets the lock, and the resolution
//! is per control. A toggle that changes only a harmless device state and reveals nothing —
//! the flashlight, airplane mode, brightness — is fine from the lock screen, because it
//! exposes no private data and takes no consequential action. A control that would reveal
//! private information or act on the person's behalf — opening the wallet to pay, unlocking
//! the front door, showing a private shortcut — stays behind the lock, usable only after the
//! person authenticates. So the quick controls panel is available while locked, but each
//! control decides for itself whether it acts or asks for a tap to unlock first, keeping the
//! panel both instantly useful and safe on a locked phone.
//!
//! This module toggles nothing. It decides whether a quick control is usable while locked,
//! from what it exposes, as a pure function.

const std = @import("std");

/// What toggling a quick control does, which decides whether it is safe from the lock screen.
pub const Effect = enum {
    /// Changes a harmless device state and reveals nothing: flashlight, airplane mode,
    /// brightness. Usable while locked.
    harmless_toggle,
    /// Reveals private information: a private shortcut, home-camera view. Requires unlock.
    reveals_private,
    /// Takes a consequential action: pay with the wallet, unlock a smart lock. Requires
    /// unlock.
    consequential,
};

/// Whether a quick control may be used while the device is locked.
///
/// A harmless toggle is usable while locked — it exposes nothing and takes no consequential
/// action. A control that reveals private information or performs a consequential action
/// requires the person to unlock first, because the lock exists precisely to gate those. The
/// default for anything beyond a harmless toggle is to require unlock.
pub fn usableWhileLocked(effect: Effect) bool {
    return effect == .harmless_toggle;
}

/// Whether a quick control may be used given the lock state.
pub fn usable(effect: Effect, locked: bool) bool {
    if (!locked) return true;
    return usableWhileLocked(effect);
}

test "harmless toggles work while locked" {
    try std.testing.expect(usable(.harmless_toggle, true));
}

test "private and consequential controls require unlock" {
    try std.testing.expect(!usable(.reveals_private, true));
    try std.testing.expect(!usable(.consequential, true));
}

test "everything works when unlocked" {
    for (std.enums.values(Effect)) |effect| {
        try std.testing.expect(usable(effect, false));
    }
}

test "no private or consequential control is ever used while locked, swept" {
    // The lock-integrity property: while locked, only harmless toggles are usable.
    for (std.enums.values(Effect)) |effect| {
        if (usable(effect, true)) try std.testing.expectEqual(Effect.harmless_toggle, effect);
    }
}
