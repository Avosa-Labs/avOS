//! Deciding who wins when two endpoints act at once, so a consequential effect is claimed by exactly
//! one endpoint and ordinary presentation state resolves without either being lost.
//!
//! Two endpoints presenting the same instance can act simultaneously — both tap "pay", or both edit
//! the same field. How the collision resolves depends entirely on what is colliding. For a
//! consequential effect — one with an external, irreversible result — the rule is exactly-once: the
//! effect is claimed against the instance before it runs, the first claim wins, and every later claim
//! for that same effect is refused so the payment is not made twice. Which endpoint got there first is
//! incidental; that only one did is the invariant. For ordinary presentation state, there is nothing
//! irreversible to protect, so a collision resolves by version order — the update built on the later
//! state supersedes the earlier — and no external harm follows either way. Separating the two is the
//! whole point: exactly-once where a repeat would cost real money or real data, last-writer-wins where
//! a repeat costs nothing. Claiming consequential effects before running them is what lets a person
//! act freely across several devices without any of them doubling an effect another already committed.
//!
//! This module performs no effect. It decides whether a claim on a consequential effect succeeds, and
//! which of two presentation updates wins, as pure functions.

const std = @import("std");

/// The result of one endpoint trying to claim a consequential effect.
pub const Claim = enum {
    /// This endpoint claimed the effect first; it may run it, once.
    won,
    /// The effect was already claimed by another endpoint; this claim is refused.
    already_claimed,
};

/// Whether a claim on a consequential effect succeeds.
///
/// The claim succeeds only if the effect has not already been claimed. Once claimed, every further
/// claim on the same effect is refused, so the external action behind it runs exactly once no matter
/// how many endpoints raced to trigger it.
pub fn claim(already_claimed: bool) Claim {
    return if (already_claimed) .already_claimed else .won;
}

/// Which of two competing presentation updates wins.
///
/// Presentation state carries no irreversible effect, so a collision is resolved by version: the
/// update built on the later version supersedes. Ties keep the incumbent, which keeps the resolution
/// deterministic. This is safe precisely because nothing external rides on the outcome.
pub fn presentationWinner(incumbent_version: u64, challenger_version: u64) enum { incumbent, challenger } {
    return if (challenger_version > incumbent_version) .challenger else .incumbent;
}

test "the first claim on a consequential effect wins" {
    try std.testing.expectEqual(Claim.won, claim(false));
}

test "a second claim on the same effect is refused" {
    try std.testing.expectEqual(Claim.already_claimed, claim(true));
}

test "a later presentation update supersedes an earlier one" {
    try std.testing.expectEqual(.challenger, presentationWinner(4, 7));
    try std.testing.expectEqual(.incumbent, presentationWinner(7, 4));
    try std.testing.expectEqual(.incumbent, presentationWinner(5, 5));
}

test "a consequential effect is claimable at most once, swept" {
    // The exactly-once property: once an effect is claimed, no further claim can win.
    try std.testing.expectEqual(Claim.won, claim(false));
    for ([_]bool{ true, true, true }) |already| {
        try std.testing.expectEqual(Claim.already_claimed, claim(already));
    }
}
