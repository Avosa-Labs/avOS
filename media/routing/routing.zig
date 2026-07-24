//! Choosing where audio comes out, so a call goes to the ear, media follows the headphones,
//! and pulling the plug never blasts private audio out the speaker.
//!
//! A device has several audio outputs — the earpiece, the loudspeaker, wired headphones, a
//! wireless headset, a car system — and only one should be active. Choosing it is a priority
//! decision shaped by two concerns: what the person plugged in, and what is safe. A connected
//! private output — headphones, a headset — is preferred, because the person chose it and it
//! keeps the audio private; a car system, when connected, takes calls and navigation. The
//! loudspeaker is the fallback when nothing private is connected. The one rule that overrides
//! preference is the safety one: when a private output disconnects mid-playback, the audio does
//! not automatically jump to the loudspeaker, because a podcast or a private call suddenly
//! playing out loud in a room is exactly the embarrassment a person fears; instead it pauses,
//! and the person chooses. Preferring the connected private output and pausing on disconnect is
//! what keeps audio going to the right place and never the wrong one.
//!
//! This module plays no audio. It chooses the active output and decides whether a disconnect
//! should pause, as pure functions.

const std = @import("std");

/// An audio output the device can route to.
pub const Output = enum {
    /// The earpiece, for a call held to the head.
    earpiece,
    /// Wired or wireless private headphones/headset.
    headphones,
    /// A connected car audio system.
    car,
    /// The built-in loudspeaker.
    loudspeaker,
};

/// What outputs are currently connected, and whether the audio is a call.
pub const Situation = struct {
    headphones_connected: bool,
    car_connected: bool,
    /// Whether the audio is a phone call, which prefers the earpiece when nothing private is
    /// connected.
    is_call: bool,
};

/// Chooses the active output for a situation.
///
/// Connected private headphones win first — the person chose them and they keep audio private.
/// A connected car system is next, for hands-free calls and navigation. Otherwise a call routes
/// to the earpiece, held to the head, and any other audio falls to the loudspeaker. The order
/// prefers privacy and the person's explicit choice over the loudspeaker.
pub fn route(situation: Situation) Output {
    if (situation.headphones_connected) return .headphones;
    if (situation.car_connected) return .car;
    if (situation.is_call) return .earpiece;
    return .loudspeaker;
}

/// Whether audio should pause when a private output disconnects mid-playback.
///
/// When headphones or a headset that was carrying the audio disconnects, playback pauses rather
/// than jumping to the loudspeaker, so private audio never suddenly plays out loud in a room.
/// The person resumes on the output they choose.
pub fn pauseOnDisconnect(was_private: bool) bool {
    return was_private;
}

fn makeSituation(headphones: bool, car: bool, call: bool) Situation {
    return .{ .headphones_connected = headphones, .car_connected = car, .is_call = call };
}

test "connected headphones win" {
    try std.testing.expectEqual(Output.headphones, route(makeSituation(true, false, false)));
    try std.testing.expectEqual(Output.headphones, route(makeSituation(true, true, true))); // even over car and call
}

test "a car system is next when no headphones" {
    try std.testing.expectEqual(Output.car, route(makeSituation(false, true, false)));
}

test "a call without private output goes to the earpiece" {
    try std.testing.expectEqual(Output.earpiece, route(makeSituation(false, false, true)));
}

test "other audio without private output goes to the loudspeaker" {
    try std.testing.expectEqual(Output.loudspeaker, route(makeSituation(false, false, false)));
}

test "disconnecting a private output pauses" {
    try std.testing.expect(pauseOnDisconnect(true));
    try std.testing.expect(!pauseOnDisconnect(false));
}

test "audio never routes to the loudspeaker while a private output is connected, swept" {
    // The privacy property: whenever headphones or a car system is connected, the route is not
    // the loudspeaker.
    for ([_]bool{ false, true }) |headphones| {
        for ([_]bool{ false, true }) |car| {
            for ([_]bool{ false, true }) |call| {
                if (headphones or car) {
                    try std.testing.expect(route(makeSituation(headphones, car, call)) != .loudspeaker);
                }
            }
        }
    }
}
