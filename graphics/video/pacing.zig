//! Deciding whether a decoded video frame should be presented or dropped, so playback
//! keeps time with the clock instead of falling behind and running in slow motion.
//!
//! Video plays back against a clock: each frame has a time it is meant to be shown, and
//! the job of pacing is to show it then. When decoding keeps up, every frame is presented
//! on time. When it falls behind — a heavy scene, a busy device — a choice appears, and
//! only one answer keeps playback watchable. Presenting every decoded frame regardless of
//! its timestamp means the video runs in slow motion and drifts ever further from the
//! audio, because the backlog never clears. Dropping a frame whose moment has already
//! passed lets playback catch up to the clock, trading a skipped frame for staying in
//! sync — which is what a person actually wants, since audio drift is far more jarring
//! than a dropped frame. So a frame that is late beyond a small tolerance is dropped, one
//! that is on time or early is presented, and playback tracks real time.
//!
//! This module decodes no video. It decides whether a frame at a given timestamp should
//! be presented or dropped against the playback clock, as a pure function.

const std = @import("std");

/// How late, in milliseconds, a frame may be and still be worth presenting. A frame later
/// than this is dropped to let playback catch up. Roughly one frame at 30 Hz.
pub const late_tolerance_ms: i64 = 33;

/// A decoded frame awaiting presentation.
pub const Frame = struct {
    /// The presentation timestamp: the clock time this frame is meant to be shown.
    presentation_ms: i64,
};

/// What to do with a frame.
pub const Decision = enum {
    /// Present the frame: it is on time, early, or only slightly late.
    present,
    /// Drop the frame: its moment has passed beyond tolerance, so showing it now would
    /// keep playback behind the clock.
    drop,

    pub fn presents(decision: Decision) bool {
        return decision == .present;
    }
};

/// Decides whether a frame should be presented, given the current clock time.
///
/// A frame whose presentation time is now or in the future is presented — it is on time
/// or early. A frame in the past is presented only if it is within the late tolerance;
/// past that it is dropped, because showing an already-late frame keeps playback behind
/// and lets audio drift. Dropping the stale frame is how playback catches up to real
/// time.
pub fn decide(frame: Frame, now_ms: i64) Decision {
    const lateness = now_ms - frame.presentation_ms;
    if (lateness > late_tolerance_ms) return .drop;
    return .present;
}

fn frameAt(presentation_ms: i64) Frame {
    return .{ .presentation_ms = presentation_ms };
}

test "an on-time frame is presented" {
    try std.testing.expectEqual(Decision.present, decide(frameAt(1000), 1000));
}

test "an early frame is presented" {
    // The clock has not reached the frame's time yet.
    try std.testing.expectEqual(Decision.present, decide(frameAt(1000), 950));
}

test "a slightly late frame within tolerance is presented" {
    try std.testing.expectEqual(Decision.present, decide(frameAt(1000), 1000 + late_tolerance_ms));
}

test "a frame late beyond tolerance is dropped" {
    try std.testing.expectEqual(Decision.drop, decide(frameAt(1000), 1000 + late_tolerance_ms + 1));
}

test "a badly stale frame is dropped" {
    try std.testing.expectEqual(Decision.drop, decide(frameAt(1000), 5000));
}

test "no frame late beyond tolerance is ever presented, swept" {
    // The catch-up property: a presented frame is never later than the tolerance allows.
    const frame = frameAt(1000);
    var now: i64 = 900;
    while (now <= 1200) : (now += 10) {
        if (decide(frame, now).presents()) {
            try std.testing.expect(now - frame.presentation_ms <= late_tolerance_ms);
        }
    }
}
