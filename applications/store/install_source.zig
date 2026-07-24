//! Deciding whether an app may install straight through or must first be acknowledged, so a
//! reviewed app from the store installs cleanly while a sideloaded package cannot slip in unnoticed.
//!
//! The store's whole safety rests on an installed app being the one that was reviewed and signed
//! through it. A package from anywhere else has had none of that scrutiny — it may be exactly what it
//! claims or it may be malware wearing a familiar icon, and the person has no store review standing
//! behind it. So an install from the store proceeds directly, its provenance already established,
//! while an install from any other source is not silently refused but gated behind an explicit
//! acknowledgement: the person must be told this app did not come through the store and did not get
//! its review, and must choose to proceed anyway. The acknowledgement exists so that installing
//! unreviewed software is always a conscious act, never something a page or a tricked tap can do on
//! the person's behalf. Letting the store install freely while making every other source stop and ask
//! keeps the safe path frictionless without closing the door on the person's own informed choice.
//!
//! This module installs nothing. It decides whether an install may proceed directly or needs an
//! explicit acknowledgement first, from the package's source, as a pure function.

const std = @import("std");

/// Where an install package came from.
pub const Source = enum {
    /// The store: reviewed, signed, and distributed through the platform's gate.
    store,
    /// Any other origin: a downloaded package, a developer build, a sideload.
    external,
};

/// The install decision.
pub const Decision = enum {
    /// The install proceeds directly, its provenance already established by the store.
    proceed,
    /// The install proceeds only after the person explicitly acknowledges its unreviewed source.
    require_acknowledgement,
    /// The install is refused.
    refuse,
};

/// Decides how an install from a given source is handled, given whether the person has acknowledged
/// an external source.
///
/// A store package proceeds directly. An external package requires an explicit acknowledgement; until
/// the person gives it, the install is held at the acknowledgement gate rather than proceeding. Once
/// acknowledged, the external install proceeds — the person made an informed choice. Nothing external
/// installs on a silent path, so unreviewed software is always something the person knowingly allowed.
pub fn decide(source: Source, acknowledged: bool) Decision {
    return switch (source) {
        .store => .proceed,
        .external => if (acknowledged) .proceed else .require_acknowledgement,
    };
}

test "a store install proceeds directly" {
    try std.testing.expectEqual(Decision.proceed, decide(.store, false));
}

test "an external install is gated on acknowledgement" {
    try std.testing.expectEqual(Decision.require_acknowledgement, decide(.external, false));
    try std.testing.expectEqual(Decision.proceed, decide(.external, true));
}

test "no external install proceeds without acknowledgement, swept" {
    // The informed-sideload property: an external install proceeds only once acknowledged.
    for ([_]bool{ false, true }) |acknowledged| {
        if (decide(.external, acknowledged) == .proceed) {
            try std.testing.expect(acknowledged);
        }
    }
}
