//! Deciding how precise a location an app receives, so a query that needs the city gets the city and
//! only an app that needs the exact spot — and was granted it — gets the exact spot.
//!
//! Location is not one thing but a dial. A weather app needs to know the person is in a city; a
//! turn-by-turn navigator needs the exact position on the road. Handing exact coordinates to the app
//! that only needed the city is an over-disclosure that, aggregated, reveals home, work, and routine.
//! So the location an app receives is reduced to the coarsest precision that its granted level allows:
//! an app granted approximate location receives a coarsened position — enough for a city or
//! neighbourhood, not a doorstep — while precise coordinates are given only to an app the person
//! granted precise access. The default grant is approximate, because most uses genuinely need no more,
//! and precise access is a deliberate step up for the few that do. Reducing to the granted precision
//! means an app's knowledge of where the person is stays matched to what it was actually trusted with.
//!
//! This module reads no sensor. It decides what precision of location an app receives, from its
//! granted level, as a pure function.

const std = @import("std");

/// The location precision an app was granted.
pub const Grant = enum {
    /// No location access.
    none,
    /// Approximate location: coarsened to roughly a city or neighbourhood.
    approximate,
    /// Precise location: exact coordinates, granted explicitly.
    precise,
};

/// The precision of location actually delivered to an app.
pub const Precision = enum {
    /// Nothing delivered.
    withheld,
    /// A coarsened position — no finer than a neighbourhood.
    coarse,
    /// Exact coordinates.
    exact,
};

/// Decides what precision of location an app receives, given its granted level.
///
/// No grant delivers nothing. An approximate grant delivers a coarsened position, never the exact
/// one. A precise grant delivers exact coordinates. The delivered precision never exceeds the grant,
/// so an app cannot obtain a finer location than the person chose to give it.
pub fn deliver(grant: Grant) Precision {
    return switch (grant) {
        .none => .withheld,
        .approximate => .coarse,
        .precise => .exact,
    };
}

test "no grant delivers no location" {
    try std.testing.expectEqual(Precision.withheld, deliver(.none));
}

test "an approximate grant delivers a coarse position" {
    try std.testing.expectEqual(Precision.coarse, deliver(.approximate));
}

test "a precise grant delivers exact coordinates" {
    try std.testing.expectEqual(Precision.exact, deliver(.precise));
}

test "exact location is delivered only under a precise grant, swept" {
    // The precision-ceiling property: an app receives exact coordinates only when granted precise.
    for ([_]Grant{ .none, .approximate, .precise }) |grant| {
        if (deliver(grant) == .exact) {
            try std.testing.expectEqual(Grant.precise, grant);
        }
    }
}
