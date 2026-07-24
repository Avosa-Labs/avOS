//! Mixing audio samples without clipping and capping the master volume, so several sounds
//! combine cleanly and the device can never blast a level that damages hearing.
//!
//! When more than one sound plays at once — a video and a notification, music and a game — the
//! samples are summed, and the sum can exceed what the output can represent. An overflowed
//! sample does not just distort, it wraps or saturates into a harsh click, the audible sign of
//! a mixer that added carelessly. So mixed samples are clamped to the representable range: a
//! sum past the ceiling holds at the ceiling, which sounds like the mix hitting full volume
//! rather than a glitch. Above the mix is a second, more important limit: the master volume is
//! capped below the hardware maximum, because a phone driving headphones at full electrical
//! output can reach levels that harm hearing, and no piece of media should be able to command
//! that. So the mixer clamps every sample and the volume path enforces a safe ceiling — one
//! keeps the sound clean, the other keeps the person safe.
//!
//! This module plays no audio. It mixes two samples with clamping and caps a volume to the
//! safe maximum, as pure functions.

const std = @import("std");

/// The range a mixed audio sample may occupy. Samples are signed; the mix must stay within.
pub const sample_min: i32 = -32768;
pub const sample_max: i32 = 32767;

/// Mixes two samples by summing and clamping to the representable range.
///
/// The sum is computed in wide arithmetic and then held within the sample range, so a
/// combination that would overflow saturates at the ceiling or floor rather than wrapping into
/// a click. Mixing silence with a sample returns the sample unchanged.
pub fn mix(a: i32, b: i32) i32 {
    const sum = @as(i64, a) + b;
    return @intCast(std.math.clamp(sum, sample_min, sample_max));
}

/// The maximum master volume, out of 100, the device will apply. Below the hardware maximum,
/// because full electrical output into headphones can reach hearing-damaging levels.
pub const safe_volume_ceiling: u8 = 85;

/// Caps a requested master volume to the safe ceiling. A volume within range is used as-is; one
/// above the ceiling is held there, so no media can command a hearing-damaging level.
pub fn capVolume(requested: u8) u8 {
    return @min(requested, safe_volume_ceiling);
}

test "mixing two samples sums them" {
    try std.testing.expectEqual(@as(i32, 300), mix(100, 200));
}

test "mixing silence returns the sample" {
    try std.testing.expectEqual(@as(i32, 500), mix(500, 0));
    try std.testing.expectEqual(@as(i32, 500), mix(0, 500));
}

test "an overflowing mix clamps to the ceiling, not wrapping" {
    try std.testing.expectEqual(sample_max, mix(30000, 30000));
    try std.testing.expectEqual(sample_min, mix(-30000, -30000));
}

test "a reasonable volume is unchanged" {
    try std.testing.expectEqual(@as(u8, 50), capVolume(50));
    try std.testing.expectEqual(safe_volume_ceiling, capVolume(safe_volume_ceiling));
}

test "a volume above the safe ceiling is capped" {
    try std.testing.expectEqual(safe_volume_ceiling, capVolume(100));
    try std.testing.expectEqual(safe_volume_ceiling, capVolume(safe_volume_ceiling + 1));
}

test "no mix ever escapes the sample range, swept" {
    // The no-clipping-glitch property: any mix of samples lands within the representable
    // range.
    const samples = [_]i32{ sample_min, -10000, 0, 10000, sample_max };
    for (samples) |a| {
        for (samples) |b| {
            const m = mix(a, b);
            try std.testing.expect(m >= sample_min and m <= sample_max);
        }
    }
}

test "no volume ever exceeds the safe ceiling, swept" {
    // The hearing-safety property: whatever is requested, the applied volume is at most the
    // ceiling.
    var v: u8 = 0;
    while (true) : (v += 5) {
        try std.testing.expect(capVolume(v) <= safe_volume_ceiling);
        if (v >= 100) break;
    }
}
