//! Deciding when a gaze dwell selects a target, so a person who controls the device with
//! their eyes can choose by looking without every glance triggering an action.
//!
//! Gaze input lets a person operate the device by looking — essential for someone who
//! cannot use their hands — and its central problem is that the eyes are always moving and
//! always pointing somewhere. If merely looking at a target activated it, the interface
//! would fire constantly as the person's gaze swept across the screen reading and scanning.
//! The answer is dwell: a target is selected only when the gaze rests on it steadily for a
//! dwell time, long enough that a passing glance does not trigger it. Two things must hold
//! for the dwell to count. The gaze must stay within a tolerance of the target — small eye
//! tremor is fine, but drifting off the target resets the dwell, because the person is no
//! longer looking at it. And the dwell must accumulate uninterrupted; a glance away and
//! back starts the timer over. Selecting only on a steady, sustained gaze is what turns
//! looking into a reliable way to choose.
//!
//! This module tracks no eyes. It decides whether a gaze dwell has selected a target, from
//! how long the gaze has rested and whether it is on target, as a pure function.

const std = @import("std");

/// How long, in milliseconds, a gaze must rest steadily on a target to select it. Long
/// enough that a passing glance does not trigger a selection.
pub const dwell_ms: i64 = 600;

/// The state of a gaze dwell on a target.
pub const Dwell = struct {
    /// Whether the gaze is currently within tolerance of the target. Drifting off resets
    /// the dwell.
    on_target: bool,
    /// How long the gaze has rested on the target uninterrupted, in milliseconds.
    dwell_ms: i64,
};

/// What a gaze dwell resolves to.
pub const Decision = enum {
    /// The dwell is complete; select the target.
    select,
    /// Keep dwelling: not yet long enough, or the gaze is off target.
    continue_dwell,

    pub fn selects(decision: Decision) bool {
        return decision == .select;
    }
};

/// Decides whether a gaze dwell selects the target.
///
/// The gaze must be on target and have rested for at least the dwell time. A gaze that has
/// drifted off target never selects, whatever its accumulated time, because the person is
/// no longer looking at the target; and a gaze that is on target but has not dwelt long
/// enough keeps dwelling, so a passing glance does not select. Only a steady, sustained
/// gaze on the target selects it.
pub fn decide(state: Dwell) Decision {
    if (!state.on_target) return .continue_dwell;
    if (state.dwell_ms >= dwell_ms) return .select;
    return .continue_dwell;
}

test "a steady gaze past the dwell time selects" {
    try std.testing.expectEqual(Decision.select, decide(.{ .on_target = true, .dwell_ms = dwell_ms }));
}

test "a passing glance does not select" {
    try std.testing.expectEqual(Decision.continue_dwell, decide(.{ .on_target = true, .dwell_ms = 100 }));
}

test "a gaze off target never selects" {
    // Even with plenty of accumulated time, an off-target gaze does not select.
    try std.testing.expectEqual(Decision.continue_dwell, decide(.{ .on_target = false, .dwell_ms = 5000 }));
}

test "the dwell threshold is inclusive" {
    try std.testing.expect(!decide(.{ .on_target = true, .dwell_ms = dwell_ms - 1 }).selects());
    try std.testing.expect(decide(.{ .on_target = true, .dwell_ms = dwell_ms }).selects());
}

test "no off-target gaze ever selects, swept" {
    // The don't-fire-on-a-glance property: selection requires the gaze to be on target.
    var t: i64 = 0;
    while (t <= 2000) : (t += 100) {
        try std.testing.expect(!decide(.{ .on_target = false, .dwell_ms = t }).selects());
    }
}

test "no selection before the dwell time, swept" {
    var t: i64 = 0;
    while (t < dwell_ms) : (t += 50) {
        try std.testing.expect(!decide(.{ .on_target = true, .dwell_ms = t }).selects());
    }
}
