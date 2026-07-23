//! Deciding when an always-listening assistant may activate and when its audio may
//! leave the device, so a wake detector does not become an open microphone.
//!
//! A voice assistant that wakes on a spoken phrase has to listen continuously for
//! that phrase, and that is the whole tension: continuous listening is exactly what
//! a covert microphone does. What keeps it acceptable is a strict boundary. The
//! detector runs entirely on the device and streams nothing anywhere; only once it
//! is confident it heard the wake phrase does the assistant activate and audio begin
//! to flow to wherever it is processed. A low-confidence maybe is not a wake, so a
//! stray syllable does not open the microphone to the network. And a wake in a
//! sensitive state is gated further: on a locked device the assistant may answer
//! what needs no private data but must not read messages or make payments without
//! the person unlocking, because a phrase anyone in earshot can speak must not reach
//! a person's secrets.
//!
//! This module captures no audio. It decides whether a detection activates the
//! assistant and whether audio may leave the device, as pure functions over the
//! detection confidence and the device state, so the open-microphone boundary is
//! enforced in one place.

const std = @import("std");

/// The minimum detector confidence, in percent, to treat a detection as a real
/// wake. Below this it is a false trigger and nothing activates or streams.
pub const wake_confidence_threshold: u8 = 90;

/// A wake detection from the on-device detector.
pub const Detection = struct {
    /// The detector's confidence that the wake phrase was spoken, 0 to 100.
    confidence: u8,
};

/// Whether the device is locked, which bounds what a wake may do.
pub const LockState = enum { locked, unlocked };

/// What a wake detection results in.
pub const Activation = enum {
    /// Not a wake: confidence too low. Nothing activates; no audio leaves.
    ignore,
    /// A wake on a locked device: the assistant answers only requests that need no
    /// private data, and a sensitive request waits for unlock.
    limited,
    /// A wake on an unlocked device: the assistant is fully available.
    full,

    /// Whether this activation permits the assistant to act at all.
    pub fn active(activation: Activation) bool {
        return activation != .ignore;
    }
};

/// Whether a detection is confident enough to be a real wake.
pub fn isWake(detection: Detection) bool {
    return detection.confidence >= wake_confidence_threshold;
}

/// Decides what a detection activates, given the device lock state.
///
/// A detection below the confidence threshold is ignored — a false trigger must not
/// open the assistant. A confident wake activates, but bounded by the lock: on an
/// unlocked device the assistant is fully available, and on a locked one it is
/// limited to requests needing no private data, so a phrase anyone can speak never
/// reaches a person's secrets.
pub fn activate(detection: Detection, lock: LockState) Activation {
    if (!isWake(detection)) return .ignore;
    return switch (lock) {
        .unlocked => .full,
        .locked => .limited,
    };
}

/// Whether audio may leave the device for a given detection.
///
/// Only a confident wake permits audio to flow off-device; below the threshold the
/// audio stays on the device and is discarded. This is the boundary that keeps the
/// always-on detector from being an open microphone: no wake, no stream.
pub fn audioMayLeaveDevice(detection: Detection) bool {
    return isWake(detection);
}

test "a confident wake on an unlocked device is fully active" {
    try std.testing.expectEqual(Activation.full, activate(.{ .confidence = 95 }, .unlocked));
}

test "a confident wake on a locked device is limited" {
    try std.testing.expectEqual(Activation.limited, activate(.{ .confidence = 95 }, .locked));
}

test "a low-confidence detection is ignored" {
    try std.testing.expectEqual(Activation.ignore, activate(.{ .confidence = 50 }, .unlocked));
    try std.testing.expectEqual(Activation.ignore, activate(.{ .confidence = 50 }, .locked));
}

test "the confidence threshold is inclusive" {
    try std.testing.expect(isWake(.{ .confidence = wake_confidence_threshold }));
    try std.testing.expect(!isWake(.{ .confidence = wake_confidence_threshold - 1 }));
}

test "audio never leaves the device below the wake threshold, swept" {
    // The open-microphone boundary: below the threshold, audio never leaves; only a
    // confident wake permits it.
    var confidence: u8 = 0;
    while (confidence < wake_confidence_threshold) : (confidence += 1) {
        try std.testing.expect(!audioMayLeaveDevice(.{ .confidence = confidence }));
    }
    try std.testing.expect(audioMayLeaveDevice(.{ .confidence = wake_confidence_threshold }));
}

test "no detection ever activates without permitting audio and vice versa, swept" {
    // Activation and audio release share the same gate: a detection activates the
    // assistant exactly when it may stream, so neither happens without the other.
    var confidence: u8 = 0;
    while (confidence <= 100) : (confidence += 5) {
        const detection: Detection = .{ .confidence = confidence };
        for ([_]LockState{ .locked, .unlocked }) |lock| {
            try std.testing.expectEqual(activate(detection, lock).active(), audioMayLeaveDevice(detection));
        }
    }
}
