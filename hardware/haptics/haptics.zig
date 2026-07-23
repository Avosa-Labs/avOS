//! Playing a haptic effect, within limits that keep it from harming the actuator
//! or the person holding the device.
//!
//! A haptic actuator is a small motor, and driving it wrongly is not merely
//! unpleasant. Held at full amplitude continuously it overheats; asked to play
//! faster than it can settle it buzzes into a blur that means nothing; run
//! without a gap between strong effects it becomes a constant vibration a person
//! cannot tell apart from a fault. So an effect is not played as requested; it is
//! played as bounded, and this module is where the bounding happens.
//!
//! It drives no motor. It takes an effect a caller wants and returns either the
//! effect adjusted to stay within the actuator's limits, or a refusal when the
//! request cannot be made safe by adjustment. The limits are logic, testable
//! across amplitudes and cadences a bench could only reach by risking the
//! actuator the limits exist to protect.

const std = @import("std");

/// Amplitude as a fraction of the actuator's maximum, in hundredths of a
/// percent. 10000 is full strength; 0 is silent.
pub const AmplitudeBasisPoints = u16;

pub const full_amplitude: AmplitudeBasisPoints = 10_000;

/// A haptic effect a caller asks to play.
pub const Effect = struct {
    amplitude: AmplitudeBasisPoints,
    /// How long the effect lasts, in milliseconds.
    duration_ms: u32,
};

/// The actuator's limits.
pub const Limits = struct {
    /// The longest a single continuous effect may run before the actuator must
    /// rest, in milliseconds. A longer effect overheats the coil.
    max_continuous_ms: u32,
    /// The shortest gap required between two strong effects, in milliseconds.
    /// Without it, back-to-back effects merge into a constant buzz.
    min_gap_ms: u32,
    /// The amplitude at or above which an effect counts as strong for the gap
    /// rule.
    strong_at: AmplitudeBasisPoints,

    /// Whether the limits are self-consistent.
    pub fn areValid(limits: Limits) bool {
        return limits.max_continuous_ms > 0 and
            limits.strong_at > 0 and
            limits.strong_at <= full_amplitude;
    }

    /// A reference actuator: no single effect over 500 ms, 50 ms between strong
    /// effects, strong at half amplitude.
    pub const reference: Limits = .{
        .max_continuous_ms = 500,
        .min_gap_ms = 50,
        .strong_at = 5_000,
    };
};

/// Why an effect was adjusted or refused.
pub const Adjustment = enum {
    /// Played as asked.
    unchanged,
    /// Shortened because it exceeded the continuous limit.
    duration_capped,
    /// Refused because too little time has passed since the last strong effect.
    refused_too_soon,
    /// Refused because the effect asks for nothing: zero amplitude or zero
    /// duration. Playing it would spin the motor up for no perceptible result.
    refused_empty,

    pub fn plays(adjustment: Adjustment) bool {
        return switch (adjustment) {
            .unchanged, .duration_capped => true,
            .refused_too_soon, .refused_empty => false,
        };
    }
};

/// What the actuator should do.
pub const Command = struct {
    effect: Effect,
    adjustment: Adjustment,
};

/// Bounds an effect against the actuator's limits.
///
/// `since_last_strong_ms` is how long it has been since the last strong effect
/// finished; the caller tracks it, because whether an effect is too soon depends
/// on what came before it. An empty effect is refused before anything else,
/// because there is nothing to bound.
pub fn shape(
    limits: Limits,
    effect: Effect,
    since_last_strong_ms: u32,
) Command {
    if (effect.amplitude == 0 or effect.duration_ms == 0) {
        return .{ .effect = .{ .amplitude = 0, .duration_ms = 0 }, .adjustment = .refused_empty };
    }

    // A strong effect too soon after the last one would merge into a buzz. The
    // gap is a limit on the actuator's behaviour, not a suggestion, so the
    // effect is refused rather than quietly weakened into something the caller
    // did not ask for.
    if (effect.amplitude >= limits.strong_at and since_last_strong_ms < limits.min_gap_ms) {
        return .{ .effect = effect, .adjustment = .refused_too_soon };
    }

    // A single effect longer than the continuous limit is capped, not refused:
    // the caller gets a real effect, just a shorter one, which is closer to
    // their intent than nothing.
    if (effect.duration_ms > limits.max_continuous_ms) {
        return .{
            .effect = .{ .amplitude = effect.amplitude, .duration_ms = limits.max_continuous_ms },
            .adjustment = .duration_capped,
        };
    }

    return .{ .effect = effect, .adjustment = .unchanged };
}

const reference = Limits.reference;

test "the reference limits are valid" {
    try std.testing.expect(reference.areValid());
}

test "a short gentle effect plays unchanged" {
    const command = shape(reference, .{ .amplitude = 3_000, .duration_ms = 100 }, 1_000);
    try std.testing.expectEqual(Adjustment.unchanged, command.adjustment);
    try std.testing.expectEqual(@as(u32, 100), command.effect.duration_ms);
}

test "an effect longer than the continuous limit is capped, not refused" {
    const command = shape(reference, .{ .amplitude = 3_000, .duration_ms = 2_000 }, 1_000);
    try std.testing.expectEqual(Adjustment.duration_capped, command.adjustment);
    // A shorter real effect is closer to intent than nothing.
    try std.testing.expectEqual(reference.max_continuous_ms, command.effect.duration_ms);
    try std.testing.expect(command.adjustment.plays());
}

test "a strong effect too soon after the last is refused" {
    // 20 ms since the last strong effect, but 50 are required.
    const command = shape(reference, .{ .amplitude = 8_000, .duration_ms = 50 }, 20);
    try std.testing.expectEqual(Adjustment.refused_too_soon, command.adjustment);
    try std.testing.expect(!command.adjustment.plays());
}

test "a strong effect after enough time plays" {
    const command = shape(reference, .{ .amplitude = 8_000, .duration_ms = 50 }, 60);
    try std.testing.expect(command.adjustment.plays());
}

test "a gentle effect is not held to the strong-effect gap" {
    // Below the strong threshold, so the gap rule does not apply even right
    // after another effect.
    const command = shape(reference, .{ .amplitude = 2_000, .duration_ms = 50 }, 0);
    try std.testing.expect(command.adjustment.plays());
}

test "an empty effect is refused" {
    // Zero amplitude or zero duration spins the motor up for no result.
    try std.testing.expectEqual(
        Adjustment.refused_empty,
        shape(reference, .{ .amplitude = 0, .duration_ms = 100 }, 1_000).adjustment,
    );
    try std.testing.expectEqual(
        Adjustment.refused_empty,
        shape(reference, .{ .amplitude = 5_000, .duration_ms = 0 }, 1_000).adjustment,
    );
}

test "no shaped effect ever exceeds the continuous limit" {
    // The property that protects the coil, swept across durations.
    var duration: u32 = 1;
    while (duration <= 5_000) : (duration += 50) {
        const command = shape(reference, .{ .amplitude = 3_000, .duration_ms = duration }, 1_000);
        if (command.adjustment.plays()) {
            try std.testing.expect(command.effect.duration_ms <= reference.max_continuous_ms);
        }
    }
}

test "the gap is measured from the last strong effect only" {
    // A strong effect exactly at the gap boundary is allowed; one basis point
    // sooner is not.
    try std.testing.expect(
        shape(reference, .{ .amplitude = 8_000, .duration_ms = 50 }, reference.min_gap_ms)
            .adjustment.plays(),
    );
    try std.testing.expect(
        !shape(reference, .{ .amplitude = 8_000, .duration_ms = 50 }, reference.min_gap_ms - 1)
            .adjustment.plays(),
    );
}
