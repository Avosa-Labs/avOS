//! Deciding whether a release may advance to a wider rollout ring, so a build reaches everyone only
//! after it has survived the smaller rings ahead of it.
//!
//! A release does not go from the build host to every device at once. It advances through rings of
//! increasing exposure — internal, then a small canary population, then a staged fraction, then
//! general availability — and the entire point of the rings is that a fault caught in a small one
//! spares the large ones. So advancing from one ring to the next is gated: the current ring must have
//! observed the build for a minimum soak, and its health must be above the threshold — no regression in
//! the crash rate or the critical signals the ring watches. A ring that has not soaked long enough, or
//! whose health has dipped, does not advance; the release holds where it is, or rolls back, rather than
//! pouring a suspect build into a bigger population. The rings only protect anyone if promotion is
//! earned by evidence from the ring below, which is exactly what this gate enforces: exposure widens
//! only behind a clean, sufficiently-observed result.
//!
//! This module ships nothing. It decides whether a release may advance to the next ring, from the
//! current ring's soak time and observed health, as a pure function.

const std = @import("std");

/// The health observed for a build in its current ring.
pub const Health = enum {
    /// No regression against the ring's thresholds.
    healthy,
    /// A regression was observed — crash rate or a critical signal past its threshold.
    regressed,
};

/// The evidence gathered from the current rollout ring.
pub const RingResult = struct {
    /// How long the build has soaked in this ring, in hours.
    soak_hours: u32,
    /// The health observed in this ring.
    health: Health,
};

/// The advancement decision.
pub const Decision = enum {
    /// The release advances to the next, wider ring.
    advance,
    /// The release holds in the current ring — not enough soak yet.
    hold,
    /// The release rolls back — a regression was observed.
    rollback,
};

/// Decides whether a release may advance to the next rollout ring.
///
/// A regression rolls the release back regardless of soak — a bad build does not earn wider exposure by
/// waiting. A healthy build that has soaked at least the required minimum advances. A healthy build that
/// has not soaked long enough holds where it is. So exposure widens only behind a clean result observed
/// for long enough to be meaningful.
pub fn decide(result: RingResult, required_soak_hours: u32) Decision {
    if (result.health == .regressed) return .rollback;
    if (result.soak_hours >= required_soak_hours) return .advance;
    return .hold;
}

fn makeResult(soak: u32, health: Health) RingResult {
    return .{ .soak_hours = soak, .health = health };
}

test "a healthy, sufficiently-soaked build advances" {
    try std.testing.expectEqual(Decision.advance, decide(makeResult(24, .healthy), 24));
}

test "a healthy build that has not soaked enough holds" {
    try std.testing.expectEqual(Decision.hold, decide(makeResult(10, .healthy), 24));
}

test "a regressed build rolls back regardless of soak" {
    try std.testing.expectEqual(Decision.rollback, decide(makeResult(100, .regressed), 24));
    try std.testing.expectEqual(Decision.rollback, decide(makeResult(0, .regressed), 24));
}

test "advancement always implies health and sufficient soak, swept" {
    // The earned-exposure property: a release advances only when healthy and soaked at least the
    // minimum.
    const required: u32 = 24;
    for ([_]Health{ .healthy, .regressed }) |health| {
        var soak: u32 = 0;
        while (soak <= 48) : (soak += 12) {
            if (decide(makeResult(soak, health), required) == .advance) {
                try std.testing.expectEqual(Health.healthy, health);
                try std.testing.expect(soak >= required);
            }
        }
    }
}
