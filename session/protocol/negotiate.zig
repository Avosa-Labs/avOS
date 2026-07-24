//! Deciding which session-protocol version a host and an endpoint speak, so they agree on the newest
//! version they both support and never fall back below the security floor.
//!
//! The live protocol between an instance host and an attached endpoint evolves: newer versions fix
//! flaws and add capabilities. When an endpoint attaches, the two sides must settle on one version to
//! speak, and that choice is where a whole class of downgrade attacks lives. Two rules govern it.
//! First, agree on the highest version both sides support, so neither is dragged back to an older
//! protocol when a newer shared one exists — the negotiated version is the maximum of the overlap.
//! Second, and overriding, never speak a version below the security floor: a version old enough to
//! have known weaknesses is not an acceptable common ground even if both sides could technically
//! speak it, so if the best they share is below the floor, negotiation fails rather than proceeding
//! insecurely. Picking the highest shared version at or above the floor is what stops an attacker who
//! influences the handshake from forcing a weak protocol on a session that could have run a strong one.
//!
//! This module speaks no protocol. It decides the negotiated version, or that none is acceptable,
//! from each side's supported range and the security floor, as a pure function.

const std = @import("std");

/// An inclusive range of protocol versions a side supports.
pub const Range = struct {
    min: u16,
    max: u16,
};

/// The result of negotiating a protocol version.
pub const Outcome = union(enum) {
    /// Both sides speak this version — the highest they share, at or above the floor.
    agreed: u16,
    /// No shared version at or above the security floor; the session must not proceed.
    incompatible,
};

/// Decides the protocol version a host and endpoint will speak.
///
/// The negotiated version is the highest both support: the smaller of the two maxima, provided it is
/// not below the larger of the two minima (that would mean the ranges do not overlap). The result
/// must also be at least the security floor. If the ranges do not overlap, or their overlap lies
/// entirely below the floor, negotiation is incompatible — the session does not silently drop to a
/// weaker protocol.
pub fn negotiate(host: Range, endpoint: Range, floor: u16) Outcome {
    const low = @max(host.min, endpoint.min);
    const high = @min(host.max, endpoint.max);
    if (low > high) return .incompatible; // No overlap.
    if (high < floor) return .incompatible; // Best shared version is below the floor.
    return .{ .agreed = high };
}

test "two overlapping ranges agree on the highest shared version" {
    try std.testing.expectEqual(Outcome{ .agreed = 4 }, negotiate(.{ .min = 2, .max = 4 }, .{ .min = 3, .max = 6 }, 1));
}

test "the negotiated version never drops below the floor" {
    // Both could speak 2, but the floor is 3 and their overlap tops out at 2.
    try std.testing.expectEqual(Outcome.incompatible, negotiate(.{ .min = 1, .max = 2 }, .{ .min = 1, .max = 2 }, 3));
}

test "disjoint ranges are incompatible" {
    try std.testing.expectEqual(Outcome.incompatible, negotiate(.{ .min = 1, .max = 2 }, .{ .min = 5, .max = 6 }, 1));
}

test "a negotiated version is always shared and at or above the floor, swept" {
    // The no-downgrade property: whenever a version is agreed, both sides support it and it meets the
    // floor.
    const ranges = [_]Range{ .{ .min = 1, .max = 3 }, .{ .min = 2, .max = 5 }, .{ .min = 4, .max = 4 } };
    const floors = [_]u16{ 1, 3, 5 };
    for (ranges) |host| {
        for (ranges) |endpoint| {
            for (floors) |floor| {
                switch (negotiate(host, endpoint, floor)) {
                    .agreed => |version| {
                        try std.testing.expect(version >= host.min and version <= host.max);
                        try std.testing.expect(version >= endpoint.min and version <= endpoint.max);
                        try std.testing.expect(version >= floor);
                    },
                    .incompatible => {},
                }
            }
        }
    }
}
