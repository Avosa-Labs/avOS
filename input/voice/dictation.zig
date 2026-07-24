//! Deciding when a person has finished speaking, so dictation commits an utterance after a
//! natural pause without cutting them off mid-sentence.
//!
//! Dictation turns speech into text, and the hardest small decision is knowing when the
//! person has stopped — endpointing. End too soon and a sentence is cut in half the moment
//! the speaker pauses for breath; end too late and the person waits, wondering whether the
//! device is still listening. The signal is silence: after speech, a stretch of quiet long
//! enough means the utterance is done. But not any quiet — a brief pause between words or
//! phrases is normal speech, so the silence must last past a threshold before the utterance
//! is committed. And silence before any speech at all is not the end of an utterance, it is
//! waiting for one to begin, so it never commits. So endpointing waits for speech, then for
//! a sufficient trailing silence, and only then decides the person is finished — long enough
//! to allow a natural pause, short enough to feel responsive.
//!
//! This module hears no audio. It decides whether an utterance is complete from whether
//! speech has occurred and how long the trailing silence has lasted, as a pure function.

const std = @import("std");

/// The trailing silence, in milliseconds, that marks the end of an utterance. Longer than a
/// natural between-phrase pause, short enough to feel responsive.
pub const endpoint_silence_ms: i64 = 700;

/// The state of an in-progress dictation.
pub const Listening = struct {
    /// Whether any speech has been detected in this utterance yet.
    speech_detected: bool,
    /// How long the current trailing silence has lasted, in milliseconds.
    trailing_silence_ms: i64,
};

/// What dictation should do.
pub const Decision = enum {
    /// Keep listening: still within an utterance or waiting for one to start.
    continue_listening,
    /// The utterance is complete; commit it.
    endpoint,

    pub fn endpoints(decision: Decision) bool {
        return decision == .endpoint;
    }
};

/// Decides whether an utterance is complete.
///
/// Silence before any speech is not the end of an utterance — dictation keeps listening,
/// waiting for the person to begin. Once speech has been detected, a trailing silence at or
/// past the endpoint threshold means the person has finished and the utterance is committed;
/// a shorter silence is a natural pause and listening continues, so a sentence is never cut
/// off between phrases.
pub fn decide(state: Listening) Decision {
    if (!state.speech_detected) return .continue_listening;
    if (state.trailing_silence_ms >= endpoint_silence_ms) return .endpoint;
    return .continue_listening;
}

test "silence before any speech keeps listening" {
    try std.testing.expectEqual(Decision.continue_listening, decide(.{ .speech_detected = false, .trailing_silence_ms = 5000 }));
}

test "a short pause after speech keeps listening" {
    try std.testing.expectEqual(Decision.continue_listening, decide(.{ .speech_detected = true, .trailing_silence_ms = 300 }));
}

test "a long trailing silence after speech endpoints" {
    try std.testing.expectEqual(Decision.endpoint, decide(.{ .speech_detected = true, .trailing_silence_ms = endpoint_silence_ms }));
}

test "the endpoint threshold is inclusive" {
    try std.testing.expect(!decide(.{ .speech_detected = true, .trailing_silence_ms = endpoint_silence_ms - 1 }).endpoints());
    try std.testing.expect(decide(.{ .speech_detected = true, .trailing_silence_ms = endpoint_silence_ms }).endpoints());
}

test "no utterance ever endpoints without speech, swept" {
    // The don't-cut-off property: endpointing only ever happens after speech has been
    // detected, whatever the silence.
    var silence: i64 = 0;
    while (silence <= 3000) : (silence += 200) {
        try std.testing.expect(!decide(.{ .speech_detected = false, .trailing_silence_ms = silence }).endpoints());
    }
}

test "no utterance endpoints before the silence threshold, swept" {
    var silence: i64 = 0;
    while (silence < endpoint_silence_ms) : (silence += 50) {
        try std.testing.expect(!decide(.{ .speech_detected = true, .trailing_silence_ms = silence }).endpoints());
    }
}
