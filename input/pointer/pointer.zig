//! Telling a click apart from a drag and applying pointer acceleration, so a small
//! shake during a click is not mistaken for a drag and slow and fast motion both feel
//! right.
//!
//! A pointer — a mouse, a trackpad — reports movement and button presses, and two small
//! decisions make it feel precise or maddening. First, a click and a drag both begin with
//! a button press, and they are told apart by movement: a press that releases without the
//! pointer moving past a small threshold is a click, while one that moves past it is a
//! drag. Without that threshold a hand that shakes a hair during a click registers a
//! one-pixel drag, and things get picked up and moved by accident. Second, raw pointer
//! movement maps poorly to the screen: at a one-to-one ratio, crossing a large display
//! needs an impractically long swipe, and fine work is jittery. Acceleration fixes both —
//! slow movement maps near one-to-one for precision, and fast movement is amplified so a
//! quick flick crosses the screen — but it must be monotonic, never mapping a larger
//! input movement to a smaller output, or the pointer stutters. Both are small rules that
//! decide whether the pointer disappears into the person's intent.
//!
//! This module moves no cursor. It classifies a press-and-release as a click or a drag and
//! computes accelerated movement, as pure functions.

const std = @import("std");

/// The distance, in device units, a pointer may move between press and release and still
/// count as a click rather than a drag.
pub const click_slop: u32 = 4;

/// Whether a press-and-release that moved `moved` device units is a click.
///
/// A movement at or below the slop threshold is a click; anything more is a drag. The
/// threshold absorbs the small unintended movement of a hand during a click, so a click is
/// not turned into an accidental drag.
pub fn isClick(moved: u32) bool {
    return moved <= click_slop;
}

/// The movement speed threshold, in device units per report, above which acceleration
/// amplifies movement. Below it, movement maps near one-to-one for precision.
pub const acceleration_threshold: u32 = 10;

/// The factor by which fast movement is amplified.
pub const fast_gain: u32 = 2;

/// Maps a raw movement magnitude to an accelerated one.
///
/// Slow movement, at or below the threshold, is passed through unchanged for fine control.
/// Fast movement, above the threshold, is amplified by the gain so a quick flick crosses
/// the screen. The mapping is monotonic — a larger raw movement never produces a smaller
/// accelerated one — so the pointer never stutters as speed crosses the threshold.
pub fn accelerate(raw: u32) u32 {
    if (raw <= acceleration_threshold) return raw;
    // Keep continuity at the threshold: the slow region ends at `threshold`, and the fast
    // region continues from there amplified, so there is no backward jump.
    return acceleration_threshold + (raw - acceleration_threshold) * fast_gain;
}

test "a press with little movement is a click" {
    try std.testing.expect(isClick(0));
    try std.testing.expect(isClick(click_slop));
}

test "a press that moves past the slop is a drag" {
    try std.testing.expect(!isClick(click_slop + 1));
    try std.testing.expect(!isClick(100));
}

test "slow movement is passed through unchanged" {
    try std.testing.expectEqual(@as(u32, 5), accelerate(5));
    try std.testing.expectEqual(acceleration_threshold, accelerate(acceleration_threshold));
}

test "fast movement is amplified" {
    // Just past the threshold, amplified by the gain.
    try std.testing.expectEqual(acceleration_threshold + fast_gain, accelerate(acceleration_threshold + 1));
}

test "acceleration is monotonic non-decreasing, swept" {
    // The no-stutter property: a larger raw movement never accelerates to a smaller
    // output.
    var raw: u32 = 0;
    var previous: u32 = 0;
    while (raw <= 100) : (raw += 1) {
        const out = accelerate(raw);
        try std.testing.expect(out >= previous);
        previous = out;
    }
}

test "acceleration is continuous at the threshold" {
    // The last slow value and the first fast value do not jump backward.
    try std.testing.expect(accelerate(acceleration_threshold + 1) >= accelerate(acceleration_threshold));
}
