//! Deciding when a held key repeats, so holding a key types a steady stream after a
//! deliberate pause rather than firing a burst the instant it is pressed.
//!
//! A held key repeats — that is how a person deletes a word or scrolls with the arrows —
//! but the timing is what makes it usable. If a key repeated immediately on press, every
//! ordinary keystroke would risk a double, because no one lifts a key instantly. So there
//! is an initial delay: a key must be held past a threshold before the first repeat, long
//! enough that a normal press never repeats but short enough that a deliberate hold feels
//! responsive. After that first repeat, the key repeats at a steady interval, and the
//! interval is fixed so the stream is even rather than accelerating out of control. The two
//! numbers — the delay before the first repeat and the interval between repeats after —
//! are the whole of it, and getting them right is the difference between a keyboard that
//! feels precise and one that types gibberish when a finger rests a moment too long.
//!
//! This module reads no keys. It decides whether a held key should emit a repeat at a
//! given moment, from how long it has been held and when it last repeated, as a pure
//! function.

const std = @import("std");

/// How long a key must be held, in milliseconds, before it repeats for the first time.
/// Longer than any ordinary keypress, so a normal press never repeats.
pub const initial_delay_ms: i64 = 400;

/// The interval, in milliseconds, between repeats after the first one. A steady rate.
pub const repeat_interval_ms: i64 = 40;

/// The state of a held key.
pub const HeldKey = struct {
    /// How long the key has been held, in milliseconds.
    held_ms: i64,
    /// When the last repeat fired, in milliseconds since the key went down, or -1 if none
    /// has fired yet.
    last_repeat_ms: i64 = -1,
};

/// Whether a held key should emit a repeat now.
///
/// Before the initial delay, no repeat fires, so an ordinary press never doubles. Once the
/// key has been held past the delay, the first repeat fires; after that, a repeat fires
/// only when the repeat interval has elapsed since the last one, so the stream is steady.
/// A key that has not been held long enough, or whose interval has not elapsed, does not
/// repeat.
pub fn shouldRepeat(key: HeldKey) bool {
    if (key.held_ms < initial_delay_ms) return false;
    if (key.last_repeat_ms < 0) return true; // first repeat, delay has passed
    return key.held_ms - key.last_repeat_ms >= repeat_interval_ms;
}

test "a key held briefly does not repeat" {
    try std.testing.expect(!shouldRepeat(.{ .held_ms = 100 }));
    try std.testing.expect(!shouldRepeat(.{ .held_ms = initial_delay_ms - 1 }));
}

test "the first repeat fires once the initial delay passes" {
    try std.testing.expect(shouldRepeat(.{ .held_ms = initial_delay_ms, .last_repeat_ms = -1 }));
}

test "after the first repeat, a repeat waits for the interval" {
    // Last repeat at 400ms; at 420ms the interval has not elapsed.
    try std.testing.expect(!shouldRepeat(.{ .held_ms = 420, .last_repeat_ms = 400 }));
    // At 440ms it has.
    try std.testing.expect(shouldRepeat(.{ .held_ms = 440, .last_repeat_ms = 400 }));
}

test "the interval boundary is inclusive" {
    try std.testing.expect(shouldRepeat(.{ .held_ms = 400 + repeat_interval_ms, .last_repeat_ms = 400 }));
}

test "no repeat ever fires before the initial delay, swept" {
    // The no-accidental-double property: below the initial delay, nothing repeats.
    var held: i64 = 0;
    while (held < initial_delay_ms) : (held += 20) {
        try std.testing.expect(!shouldRepeat(.{ .held_ms = held, .last_repeat_ms = -1 }));
    }
}

test "repeats after the first are spaced at least the interval apart, swept" {
    // The steady-rate property: with a last-repeat time, a repeat fires only once the
    // interval has elapsed.
    const last: i64 = 500;
    var held: i64 = last;
    while (held <= last + 2 * repeat_interval_ms) : (held += 5) {
        if (shouldRepeat(.{ .held_ms = held, .last_repeat_ms = last })) {
            try std.testing.expect(held - last >= repeat_interval_ms);
        }
    }
}
