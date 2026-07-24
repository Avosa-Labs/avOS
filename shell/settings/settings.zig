//! Deciding whether a settings change may be applied, so a security-sensitive setting cannot
//! be flipped without the person authenticating even if the settings surface is open.
//!
//! Settings is where the device is configured, and not all settings are equal. Most — the
//! wallpaper, the text size, whether an app may notify — are the person's to change freely,
//! and gating them behind a password would be friction with no benefit. But some settings are
//! the security of the device itself: turning off the screen lock, disabling a theft
//! protection, changing who may unlock. Flipping one of those is exactly what an attacker who
//! has a briefly-unlocked phone wants to do, so those changes require the person to
//! authenticate at the moment of the change, not merely to have unlocked the phone earlier.
//! The distinction is per setting: an ordinary setting applies immediately, a protected one
//! applies only against a fresh authentication. This keeps configuration effortless where it
//! is harmless and firmly gated where a change would weaken the device's defenses.
//!
//! This module changes no setting. It decides whether a change may be applied, from the
//! setting's sensitivity and whether the person has freshly authenticated, as a pure
//! function.

const std = @import("std");

/// How sensitive a setting is, which decides whether changing it needs fresh authentication.
pub const Sensitivity = enum {
    /// An ordinary preference: appearance, per-app toggles. Applies immediately.
    ordinary,
    /// A security-sensitive setting: the screen lock, theft protection, unlock policy.
    /// Requires fresh authentication to change.
    security,
};

/// Why a settings change was blocked.
pub const Refusal = enum {
    /// The setting is security-sensitive and no fresh authentication was presented.
    authentication_required,
};

/// The outcome of a settings change.
pub const Decision = union(enum) {
    apply,
    refuse: Refusal,

    pub fn applies(decision: Decision) bool {
        return decision == .apply;
    }
};

/// Decides whether a settings change may be applied.
///
/// An ordinary setting applies immediately. A security-sensitive setting applies only when
/// the person has freshly authenticated for this change — not merely unlocked the device
/// earlier — because weakening the device's defenses is exactly what someone with a
/// briefly-borrowed phone would attempt. Without fresh authentication, a security change is
/// refused.
pub fn decide(sensitivity: Sensitivity, freshly_authenticated: bool) Decision {
    return switch (sensitivity) {
        .ordinary => .apply,
        .security => if (freshly_authenticated) .apply else .{ .refuse = .authentication_required },
    };
}

test "an ordinary setting applies immediately" {
    try std.testing.expect(decide(.ordinary, false).applies());
    try std.testing.expect(decide(.ordinary, true).applies());
}

test "a security setting needs fresh authentication" {
    try std.testing.expectEqual(Decision{ .refuse = .authentication_required }, decide(.security, false));
    try std.testing.expect(decide(.security, true).applies());
}

test "no security setting ever applies without fresh authentication, swept" {
    // The defense-protection property: a security change that applied was freshly
    // authenticated.
    for ([_]bool{ false, true }) |fresh| {
        if (decide(.security, fresh).applies()) try std.testing.expect(fresh);
    }
}
