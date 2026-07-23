//! Arbitrating audio focus between apps, so two sounds do not fight over the
//! speaker and a phone call is never drowned out by a song.
//!
//! Only one thing should own the speaker at a time, or the person hears a mess: a
//! podcast and a game blaring together, a navigation prompt lost under music. Audio
//! focus is how the system decides who owns it. A new request is weighed against the
//! current holder by priority: a higher-priority sound takes focus, and what happens
//! to the one it displaces depends on how much it can tolerate sharing — music ducks
//! quietly under a short navigation prompt and resumes, but yields entirely to a
//! phone call. The one rule that never bends is that a call, and the alerts that
//! must be heard, sit at the top: nothing a mere app plays can take focus from a
//! call or keep a call from taking it, because a missed call because a game refused
//! to quiet down is the system failing at the thing a phone is for.
//!
//! This module plays no sound. It decides whether a focus request is granted and
//! what becomes of the current holder — kept, ducked, or paused — as a pure function
//! over the two priorities and the request's nature.

const std = @import("std");

/// How important a sound is, ordered so a comparison decides who owns the speaker.
pub const Priority = enum(u8) {
    /// Background ambience, low-value effects. Yields to anything.
    ambient = 0,
    /// Media: music, video, a game. The ordinary case.
    media = 1,
    /// A transient prompt: navigation, an assistant reply. Briefly interrupts media.
    transient = 2,
    /// A call or an alert that must be heard. Tops everything.
    call = 3,

    fn outranks(priority: Priority, other: Priority) bool {
        return @intFromEnum(priority) > @intFromEnum(other);
    }
};

/// Whether a request wants the holder silenced or merely lowered while it plays.
pub const Share = enum {
    /// The request is brief and can share: the holder ducks quietly and resumes.
    transient_may_duck,
    /// The request needs the speaker to itself: the holder is paused.
    exclusive,
};

/// What happens to the current holder when a request is granted.
pub const HolderOutcome = enum {
    /// The holder keeps focus; the request was denied.
    keep,
    /// The holder lowers its volume under the request and resumes after.
    duck,
    /// The holder loses focus and is paused.
    pause,
};

/// The outcome of a focus request.
pub const Decision = struct {
    granted: bool,
    /// What becomes of the previous holder. Meaningful only when granted; `keep`
    /// when the request was denied.
    holder: HolderOutcome,
};

/// Decides a focus request against the current holder.
///
/// A request that does not outrank the holder is denied and the holder keeps focus —
/// music does not interrupt a call, and a second song does not seize the speaker from
/// the first. A request that outranks the holder is granted, and the holder ducks if
/// the request is a brief shareable prompt or is paused if the request needs the
/// speaker to itself. A call outranks everything an app can play, so it is always
/// granted focus over media.
pub fn request(holder: Priority, requester: Priority, share: Share) Decision {
    if (!requester.outranks(holder)) {
        return .{ .granted = false, .holder = .keep };
    }
    return switch (share) {
        .transient_may_duck => .{ .granted = true, .holder = .duck },
        .exclusive => .{ .granted = true, .holder = .pause },
    };
}

test "a higher priority takes focus and pauses the holder" {
    const decision = request(.media, .call, .exclusive);
    try std.testing.expect(decision.granted);
    try std.testing.expectEqual(HolderOutcome.pause, decision.holder);
}

test "a transient prompt ducks the holder rather than pausing it" {
    const decision = request(.media, .transient, .transient_may_duck);
    try std.testing.expect(decision.granted);
    try std.testing.expectEqual(HolderOutcome.duck, decision.holder);
}

test "an equal or lower priority is denied and the holder keeps focus" {
    const equal = request(.media, .media, .exclusive);
    try std.testing.expect(!equal.granted);
    try std.testing.expectEqual(HolderOutcome.keep, equal.holder);

    const lower = request(.call, .media, .exclusive);
    try std.testing.expect(!lower.granted);
}

test "a call always takes focus over media, swept" {
    // The call-wins property: whatever an app is playing below call priority, a call
    // is granted focus.
    for ([_]Priority{ .ambient, .media, .transient }) |holder| {
        const decision = request(holder, .call, .exclusive);
        try std.testing.expect(decision.granted);
    }
}

test "nothing an app plays takes focus from a call, swept" {
    // The reverse: no priority below call ever seizes focus from a call.
    for ([_]Priority{ .ambient, .media, .transient }) |requester| {
        for ([_]Share{ .transient_may_duck, .exclusive }) |share| {
            try std.testing.expect(!request(.call, requester, share).granted);
        }
    }
}

test "a granted request always outranks the holder, swept" {
    for (std.enums.values(Priority)) |holder| {
        for (std.enums.values(Priority)) |requester| {
            for ([_]Share{ .transient_may_duck, .exclusive }) |share| {
                if (request(holder, requester, share).granted) {
                    try std.testing.expect(requester.outranks(holder));
                }
            }
        }
    }
}
