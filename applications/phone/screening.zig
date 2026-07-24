//! Deciding whether an incoming call rings the person or is screened first, so a spoofed or
//! unknown caller cannot demand attention while a genuine one still gets through — and an
//! emergency call is always dialable.
//!
//! Caller ID is trivially forged, and the whole economy of scam and fraud calls rests on a
//! stranger's number looking like it might be someone worth answering. So an incoming call rings
//! straight through only when the platform can vouch for who is calling: a caller already in the
//! person's contacts, or an unknown number whose network attestation checks out. An unknown,
//! unattested, or failed-attestation number is not refused — the person may still want it — but it
//! is screened rather than allowed to interrupt, so the burden of proof sits with the caller and
//! not the person. The one carve-out runs the other way: dialling an emergency number is always
//! permitted, even from a locked device with no service plan, because a safety call must never be
//! gated on anything.
//!
//! This module places no call. It decides whether an incoming call rings or is screened, and
//! whether an outbound number is always dialable, as pure functions.

const std = @import("std");

/// Where an incoming caller's number stands with the platform.
pub const Caller = enum {
    /// A number already in the person's contacts. Trusted to ring.
    known,
    /// An unknown number the network cryptographically attested (STIR/SHAKEN-style). Rings.
    attested,
    /// An unknown number with no attestation, or one whose attestation failed. Screened.
    unverified,
};

/// What happens to an incoming call.
pub const Handling = enum {
    /// The call rings the person immediately.
    ring,
    /// The call is intercepted and screened before it may reach the person.
    screen,
};

/// Decides how an incoming call is handled.
///
/// A known contact or a validly attested number rings through; anything unverified is screened.
/// Screening is not rejection — it withholds the interruption until the caller has shown who they
/// are, which is what stops forged caller ID from being enough to make a phone ring.
pub fn handle(caller: Caller) Handling {
    return switch (caller) {
        .known, .attested => .ring,
        .unverified => .screen,
    };
}

/// Whether a dialled number may always be placed regardless of device state.
///
/// An emergency number is dialable from a locked device, with no SIM, and with no service plan,
/// because a safety call must never depend on authentication, billing, or configuration. Every
/// other number follows the normal path.
pub fn alwaysDialable(is_emergency_number: bool) bool {
    return is_emergency_number;
}

test "a known contact rings through" {
    try std.testing.expectEqual(Handling.ring, handle(.known));
}

test "an attested unknown number rings through" {
    try std.testing.expectEqual(Handling.ring, handle(.attested));
}

test "an unverified number is screened, not rung" {
    try std.testing.expectEqual(Handling.screen, handle(.unverified));
}

test "an emergency number is always dialable; an ordinary number is not unconditionally" {
    try std.testing.expect(alwaysDialable(true));
    try std.testing.expect(!alwaysDialable(false));
}

test "only a vouched-for caller ever rings, swept" {
    // The interruption property: a call rings only when the platform can attest the caller.
    for ([_]Caller{ .known, .attested, .unverified }) |caller| {
        if (handle(caller) == .ring) {
            try std.testing.expect(caller == .known or caller == .attested);
        }
    }
}
