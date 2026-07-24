//! Deciding what capabilities the calculator may hold, so the simplest app on the device is also the
//! proof that least privilege is real: it holds none.
//!
//! A calculator adds numbers. It has no reason to touch the network, read a file, see the person's
//! location, or reach any contact. An app that needs nothing should be able to request nothing and be
//! trusted precisely because it can do nothing else — a sealed app whose blast radius, if it were
//! ever compromised, is arithmetic. So the calculator declares an empty capability set, and any
//! capability request attributed to it is refused on that ground alone, without consulting a prompt or
//! a policy: a request from a principal that declared no capabilities is a contradiction, and the
//! contradiction is resolved by refusal. This is not a special case for one app but the general shape
//! of least privilege made concrete — the platform can hold an app to exactly what it declared, and
//! for the calculator that is nothing. A zero-capability app that stays zero-capability is the
//! cleanest demonstration the containment model works.
//!
//! This module computes nothing. It decides whether a capability request from a sealed, zero-
//! capability app may be granted, as a pure function — and the answer is always no.

const std = @import("std");

/// A capability a running app might request.
pub const Capability = enum {
    network,
    files,
    location,
    contacts,
    camera,
    microphone,
};

/// The calculator's declared capability set: empty. It requests, and is granted, nothing.
pub const declared_capabilities = [_]Capability{};

/// Whether the sealed calculator app may hold a capability.
///
/// It may hold a capability only if that capability is in its declared set — and its declared set is
/// empty, so every capability is refused. The refusal follows from the declaration, not from a
/// runtime prompt, which is what makes the app's containment a static guarantee rather than a hope.
pub fn mayHold(capability: Capability) bool {
    for (declared_capabilities) |declared| {
        if (declared == capability) return true;
    }
    return false;
}

test "the calculator declares no capabilities" {
    try std.testing.expectEqual(@as(usize, 0), declared_capabilities.len);
}

test "every capability request from the calculator is refused, swept" {
    // The sealed-app property: a zero-capability app holds no capability, whichever is asked for.
    for (std.enums.values(Capability)) |capability| {
        try std.testing.expect(!mayHold(capability));
    }
}
