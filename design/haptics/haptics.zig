//! Deciding whether a haptic plays and at what strength, honouring a person's system
//! haptics setting while letting essential feedback through, so the device is not buzzing
//! constantly but still confirms the actions that need it.
//!
//! Haptics — the small taps and buzzes a phone makes — are feedback, and like sound they
//! can be overdone. A person who turns system haptics off, or down, is asking the device
//! to stop vibrating for every little thing, and most haptics should obey: the tick as a
//! picker scrolls, the tap on a key. But a few haptics are not decoration, they are how a
//! person knows something happened when they cannot look — the confirmation that a payment
//! went through, the distinct buzz of an alarm or an urgent alert. Those play regardless of
//! the setting, at a strength the person can feel, because suppressing them removes the only
//! signal for an action that matters. So a haptic carries a role, and whether and how
//! strongly it plays depends on that role against the person's haptics level: decorative
//! haptics scale down and off with the setting, essential ones always play at a perceptible
//! strength.
//!
//! This module fires no actuator. It decides whether a haptic plays and its strength, from
//! its role and the person's haptics level, as a pure function.

const std = @import("std");

/// What a haptic is for, which sets whether the person's setting may suppress it.
pub const Role = enum {
    /// Decorative feedback: scroll ticks, selection taps. Scales with the setting and
    /// stops when it is off.
    decorative,
    /// Essential confirmation: a payment succeeded, an alarm, an urgent alert. Always
    /// plays at a perceptible strength.
    essential,
};

/// The person's system haptics level, 0 (off) to 100 (full).
pub const Level = u8;

/// The minimum strength, out of 100, at which an essential haptic plays so it is
/// perceptible even when the person has turned the level down.
pub const essential_floor: u8 = 40;

/// The strength a haptic plays at, 0 to 100. Zero means it does not play.
pub const Strength = u8;

/// Decides the strength a haptic plays at, given its role and the person's level.
///
/// A decorative haptic plays at the person's level and stops entirely when the level is
/// zero, so turning haptics off silences the constant little buzzes. An essential haptic
/// plays at the person's level but never below a perceptible floor, so a payment
/// confirmation or an alarm can always be felt even when the person has dialled decorative
/// feedback down. The floor is the whole point: essential feedback is never suppressed into
/// imperceptibility.
pub fn strength(role: Role, level: Level) Strength {
    return switch (role) {
        .decorative => level,
        .essential => @max(level, essential_floor),
    };
}

/// Whether a haptic plays at all.
pub fn plays(role: Role, level: Level) bool {
    return strength(role, level) > 0;
}

test "a decorative haptic plays at the person's level" {
    try std.testing.expectEqual(@as(Strength, 70), strength(.decorative, 70));
}

test "a decorative haptic is silent when haptics are off" {
    try std.testing.expectEqual(@as(Strength, 0), strength(.decorative, 0));
    try std.testing.expect(!plays(.decorative, 0));
}

test "an essential haptic plays at the person's level when above the floor" {
    try std.testing.expectEqual(@as(Strength, 80), strength(.essential, 80));
}

test "an essential haptic never falls below the perceptible floor" {
    try std.testing.expectEqual(essential_floor, strength(.essential, 10));
    try std.testing.expectEqual(essential_floor, strength(.essential, 0));
    try std.testing.expect(plays(.essential, 0));
}

test "an essential haptic is always perceptible, swept" {
    // The safety property: whatever the person's level, an essential haptic plays at at
    // least the floor.
    var level: Level = 0;
    while (true) : (level += 10) {
        try std.testing.expect(strength(.essential, level) >= essential_floor);
        if (level >= 100) break;
    }
}

test "a decorative haptic never exceeds the person's level, swept" {
    // The obey-the-setting property: decorative feedback is capped at what the person
    // chose.
    var level: Level = 0;
    while (true) : (level += 10) {
        try std.testing.expect(strength(.decorative, level) <= level);
        if (level >= 100) break;
    }
}
