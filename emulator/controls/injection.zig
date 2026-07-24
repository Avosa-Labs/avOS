//! Deciding how injected input is attributed on a virtual device, so emulator-driven events are always
//! marked synthetic and can never launder into input trusted as a present human.
//!
//! The emulator drives a virtual device by injecting input events — taps, keystrokes, gestures — from a
//! test harness or a script. That is exactly what makes it useful and exactly what makes it dangerous to
//! attribute carelessly: if injected input were indistinguishable from a person physically present at the
//! device, then a test script, or anything that could reach the injection channel, would carry the
//! authority of a human at the keyboard — able to approve, to authorize, to act as the owner. So injected
//! input is stamped synthetic at the point of injection and keeps that provenance downstream: a decision
//! that requires the authority of a present human is refused for synthetic input, no matter that the
//! event looks identical to a real one. Genuine human input on a real device carries human provenance;
//! emulator injection never does, and cannot relabel itself to acquire it. Preserving the synthetic mark
//! is what lets the emulator exercise every input path without any of that exercise counting as a person's
//! consent.
//!
//! This module injects nothing. It decides the provenance of an input event and whether it may satisfy a
//! decision needing present-human authority, as pure functions.

const std = @import("std");

/// Where an input event came from.
pub const Provenance = enum {
    /// A person physically present at a real device.
    present_human,
    /// Injected by the emulator — a harness, a script, a recorded sequence.
    synthetic,
};

/// The provenance the emulator stamps on an event it injects.
///
/// Always synthetic. There is no path by which injection produces a present-human event, which is the
/// whole guarantee: the emulator cannot manufacture human authority.
pub fn injectedProvenance() Provenance {
    return .synthetic;
}

/// Whether an input event may satisfy a decision that requires the authority of a present human.
///
/// Only present-human provenance qualifies. Synthetic input — everything the emulator injects — never
/// does, so an approval or authorization gated on a real person is not obtainable by injection.
pub fn mayAuthorizeAsHuman(provenance: Provenance) bool {
    return provenance == .present_human;
}

test "injected input is always synthetic" {
    try std.testing.expectEqual(Provenance.synthetic, injectedProvenance());
}

test "synthetic input cannot authorize as a human" {
    try std.testing.expect(!mayAuthorizeAsHuman(injectedProvenance()));
    try std.testing.expect(!mayAuthorizeAsHuman(.synthetic));
}

test "only present-human input authorizes" {
    try std.testing.expect(mayAuthorizeAsHuman(.present_human));
}

test "no injected event ever carries human authority, swept" {
    // The no-laundering property: the emulator's injected provenance never satisfies human authority.
    try std.testing.expect(!mayAuthorizeAsHuman(injectedProvenance()));
    for ([_]Provenance{ .present_human, .synthetic }) |provenance| {
        if (mayAuthorizeAsHuman(provenance)) {
            try std.testing.expectEqual(Provenance.present_human, provenance);
        }
    }
}
