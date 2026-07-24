//! Deciding whether changing a setting requires the person to re-authenticate, so a device left
//! unlocked for a moment cannot have its safety settings quietly turned off.
//!
//! Not every setting carries the same weight. Changing the wallpaper is harmless; disabling the
//! device locator, changing the passcode, or erasing the device is the kind of change that, made by
//! the wrong hands, hands over or destroys everything. The threat is the unattended unlocked device
//! — a phone set down for a minute, a thief who grabbed it still unlocked — where an attacker's goal
//! is to sever the owner's control before the owner notices. So a sensitive setting change demands a
//! fresh authentication at the moment of the change, not merely that the device was unlocked at some
//! earlier point. A recent unlock is not consent to disable the very protections that would let the
//! owner recover the device. Ordinary settings change freely; the sensitive ones re-check that the
//! person present is the owner, which is what stops a brief lapse in physical control from becoming a
//! permanent loss.
//!
//! This module changes no setting. It decides whether a setting change is permitted, from the
//! setting's sensitivity and whether a fresh authentication was just provided, as a pure function.

const std = @import("std");

/// How consequential changing a setting is.
pub const Sensitivity = enum {
    /// A routine setting: appearance, sounds, layout. Changes without re-authentication.
    ordinary,
    /// A safety-critical setting: disabling the locator, changing the passcode, erasing the device.
    /// Requires a fresh authentication.
    sensitive,
};

/// Whether a setting change is permitted.
///
/// An ordinary setting changes without ceremony. A sensitive setting changes only when a fresh
/// authentication accompanies the change, so the protections that let an owner recover a lost device
/// cannot be switched off on the strength of an unlock that happened moments earlier for something
/// else.
pub fn mayChange(sensitivity: Sensitivity, fresh_auth: bool) bool {
    return switch (sensitivity) {
        .ordinary => true,
        .sensitive => fresh_auth,
    };
}

test "an ordinary setting changes without re-authentication" {
    try std.testing.expect(mayChange(.ordinary, false));
}

test "a sensitive setting requires fresh authentication" {
    try std.testing.expect(!mayChange(.sensitive, false));
    try std.testing.expect(mayChange(.sensitive, true));
}

test "a sensitive change always carries a fresh auth, swept" {
    // The re-authentication property: a permitted sensitive change was freshly authenticated.
    for ([_]bool{ false, true }) |fresh| {
        if (mayChange(.sensitive, fresh)) {
            try std.testing.expect(fresh);
        }
    }
}
