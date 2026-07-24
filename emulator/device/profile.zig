//! Deciding whether a virtual device profile is coherent enough to instantiate, so an emulated device
//! presents a consistent, honest set of capabilities rather than an impossible one.
//!
//! A virtual device is defined by a profile: how much memory it has, which form factor it emulates,
//! which hardware capabilities it exposes. Because software downstream — the shell, the apps, the
//! capability checks — reasons about the device from this profile, an incoherent profile is not a
//! harmless misconfiguration but a source of decisions made against a device that could not exist.
//! So a profile is validated before a device is instantiated from it: it must claim a positive amount
//! of memory, name a form factor the platform recognizes, and not both claim a capability and its
//! contradiction. A profile that passes is safe to build a virtual device on; one that fails is
//! rejected with the reason rather than instantiated into a device whose stated capabilities lie about
//! what it can do. Validating the profile up front is what keeps the emulated device a faithful stand-in
//! for a real one instead of a configuration no hardware would ever match.
//!
//! This module instantiates nothing. It decides whether a virtual device profile is coherent, from
//! its memory, form factor, and capability flags, as a pure function.

const std = @import("std");

/// The form factor a virtual device emulates.
pub const FormFactor = enum { phone, tablet, desktop, wearable, spatial, vehicle, room, robot, screenless };

/// A virtual device profile presented for instantiation.
pub const Profile = struct {
    /// Emulated memory in mebibytes. Must be positive.
    memory_mib: u32,
    /// The form factor emulated.
    form_factor: FormFactor,
    /// Whether the profile claims a display.
    has_display: bool,
    /// Whether the profile claims touch input. Touch without a display is incoherent.
    has_touch: bool,
};

/// Why a profile was rejected.
pub const Rejection = enum {
    /// The profile claims no memory.
    no_memory,
    /// The profile claims touch input without a display to touch.
    touch_without_display,
};

/// The validation result.
pub const Validity = union(enum) {
    ok,
    rejected: Rejection,

    pub fn isOk(validity: Validity) bool {
        return validity == .ok;
    }
};

/// Whether a virtual device profile is coherent enough to instantiate.
///
/// The profile must claim positive memory, and it must not claim touch input without a display — a
/// device you could touch but not see is not a device. A coherent profile is accepted; an incoherent
/// one is rejected with the reason, so no virtual device is built on a self-contradictory description.
pub fn validate(profile: Profile) Validity {
    if (profile.memory_mib == 0) return .{ .rejected = .no_memory };
    if (profile.has_touch and !profile.has_display) return .{ .rejected = .touch_without_display };
    return .ok;
}

fn makeProfile(memory: u32, form_factor: FormFactor, display: bool, touch: bool) Profile {
    return .{ .memory_mib = memory, .form_factor = form_factor, .has_display = display, .has_touch = touch };
}

test "a coherent profile is accepted" {
    try std.testing.expect(validate(makeProfile(2048, .phone, true, true)).isOk());
}

test "a profile with no memory is rejected" {
    try std.testing.expectEqual(Validity{ .rejected = .no_memory }, validate(makeProfile(0, .phone, true, true)));
}

test "touch without a display is rejected" {
    try std.testing.expectEqual(Validity{ .rejected = .touch_without_display }, validate(makeProfile(1024, .phone, false, true)));
}

test "a screenless profile without touch or display is fine" {
    try std.testing.expect(validate(makeProfile(512, .screenless, false, false)).isOk());
}

test "an accepted profile is always coherent, swept" {
    // The coherence property: an accepted profile has positive memory and never touch-without-display.
    const memories = [_]u32{ 0, 1024 };
    for (memories) |memory| {
        for ([_]bool{ false, true }) |display| {
            for ([_]bool{ false, true }) |touch| {
                if (validate(makeProfile(memory, .phone, display, touch)).isOk()) {
                    try std.testing.expect(memory > 0);
                    try std.testing.expect(display or !touch);
                }
            }
        }
    }
}
