//! The playback state machine and seek clamping, so transport controls behave predictably and
//! a seek never lands outside the media.
//!
//! Media playback has a small set of states — stopped, playing, paused — and the transport
//! controls move between them. Which moves are valid seems obvious until the edges: pressing
//! play on already-playing media should be a harmless no-op, not an error; pausing stopped
//! media does nothing; and stop is always available. Getting the machine right is what keeps a
//! double-tap or a race between the lock screen and the app from wedging playback into a state
//! the controls cannot recover from. Alongside the state is the position, and seeking has one
//! rule that must hold: a seek target is clamped into the media's duration, because seeking
//! before the start or past the end has no valid frame to show and a player that trusts an
//! out-of-range position reads garbage or crashes. So playback is a clear state machine with a
//! clamped position — simple, but exact, because the transport controls are touched constantly
//! and must never surprise the person.
//!
//! This module plays nothing. It decides valid playback transitions and clamps a seek position,
//! as pure functions.

const std = @import("std");

/// The states playback may be in.
pub const State = enum { stopped, playing, paused };

/// A transport command.
pub const Command = enum { play, pause, stop };

/// The state a command produces from the current state.
///
/// Play moves stopped or paused media to playing and leaves already-playing media playing (a
/// harmless no-op). Pause moves playing media to paused and leaves other states unchanged. Stop
/// always moves to stopped, so playback can always be halted. Every command is valid from every
/// state — the machine has no illegal moves, only no-ops — so the transport controls never wedge.
pub fn apply(state: State, command: Command) State {
    return switch (command) {
        .play => .playing,
        .pause => if (state == .playing) .paused else state,
        .stop => .stopped,
    };
}

/// Clamps a seek target into the media's duration.
///
/// A target below zero clamps to the start and one past the duration clamps to the end, so a
/// seek always lands on a valid position within the media. Seeking a zero-length media returns
/// zero.
pub fn clampSeek(target_ms: i64, duration_ms: i64) i64 {
    if (duration_ms <= 0) return 0;
    return std.math.clamp(target_ms, 0, duration_ms);
}

test "play starts stopped or paused media" {
    try std.testing.expectEqual(State.playing, apply(.stopped, .play));
    try std.testing.expectEqual(State.playing, apply(.paused, .play));
}

test "play on playing media is a no-op" {
    try std.testing.expectEqual(State.playing, apply(.playing, .play));
}

test "pause only affects playing media" {
    try std.testing.expectEqual(State.paused, apply(.playing, .pause));
    try std.testing.expectEqual(State.stopped, apply(.stopped, .pause));
    try std.testing.expectEqual(State.paused, apply(.paused, .pause));
}

test "stop always stops" {
    for (std.enums.values(State)) |state| {
        try std.testing.expectEqual(State.stopped, apply(state, .stop));
    }
}

test "a seek within the media is unchanged" {
    try std.testing.expectEqual(@as(i64, 5000), clampSeek(5000, 10000));
}

test "a seek before the start clamps to zero" {
    try std.testing.expectEqual(@as(i64, 0), clampSeek(-100, 10000));
}

test "a seek past the end clamps to the duration" {
    try std.testing.expectEqual(@as(i64, 10000), clampSeek(20000, 10000));
}

test "a seek on zero-length media returns zero" {
    try std.testing.expectEqual(@as(i64, 0), clampSeek(500, 0));
}

test "no seek ever lands outside the media, swept" {
    // The valid-position property: a clamped seek is always within [0, duration].
    const duration: i64 = 8000;
    var target: i64 = -2000;
    while (target <= 12000) : (target += 1000) {
        const clamped = clampSeek(target, duration);
        try std.testing.expect(clamped >= 0 and clamped <= duration);
    }
}

test "stop is reachable from every state, swept" {
    // The never-wedged property: stop always halts, from any state.
    for (std.enums.values(State)) |state| {
        try std.testing.expectEqual(State.stopped, apply(state, .stop));
    }
}
