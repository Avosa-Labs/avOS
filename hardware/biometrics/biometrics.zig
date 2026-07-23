//! Matching a person against an enrolled template, and knowing when to stop
//! trusting the match.
//!
//! A biometric is a convenience wrapped around a genuine risk. It is not a
//! secret — a face is on display, a fingerprint is left on everything touched —
//! so it authenticates presence, not identity, and it must fail toward the
//! passcode rather than toward access. This module holds the matching policy:
//! how confident a match must be, how many attempts are allowed before the
//! biometric is disabled and only the passcode will do, and when a prior match
//! has gone stale.
//!
//! It runs no sensor and stores no template. The comparison a sensor performs
//! returns a similarity score; this decides what that score means, given the
//! recent history of attempts and how long ago the person last proved
//! themselves the hard way. The policy is logic, testable across score
//! sequences a real sensor would take a person many tries to produce.

const std = @import("std");

/// A match score as a fraction, in hundredths of a percent. Higher is a closer
/// match; 10000 is identical, which no live capture ever reaches.
pub const ScoreBasisPoints = u16;

/// The biometric modalities a device may have.
pub const Modality = enum {
    fingerprint,
    face,

    /// The score a match must reach for this modality to be accepted.
    ///
    /// Face is held to a higher bar than fingerprint because it is easier to
    /// present a photograph of a face than a copy of a fingertip, so a face
    /// match must be more certain to carry the same weight.
    pub fn acceptanceThreshold(modality: Modality) ScoreBasisPoints {
        return switch (modality) {
            .fingerprint => 8_000,
            .face => 9_000,
        };
    }
};

/// Why a biometric attempt did not grant access.
pub const Refusal = enum {
    /// The score was below the modality's threshold. Try again.
    below_threshold,
    /// Too many failures in a row. The biometric is disabled until the passcode
    /// is entered. The fallback to a known-hard secret is the whole safety net.
    locked_out,
    /// A match was accepted earlier but has since gone stale, so this operation
    /// needs a fresh proof rather than riding the old one.
    match_expired,
};

/// The outcome of an attempt.
pub const Outcome = union(enum) {
    /// Accepted. Carries the score so a caller can log how certain it was.
    accepted: ScoreBasisPoints,
    /// Refused, with the reason.
    refused: Refusal,

    pub fn wasAccepted(outcome: Outcome) bool {
        return outcome == .accepted;
    }
};

/// How the biometric behaves under repeated failure and over time.
pub const Policy = struct {
    /// Consecutive failures allowed before the biometric locks out and only the
    /// passcode will do.
    max_consecutive_failures: u8,
    /// How long an accepted match stays valid for follow-on operations, in
    /// seconds. After this a fresh proof is required.
    match_valid_seconds: u32,

    pub fn isValid(policy: Policy) bool {
        return policy.max_consecutive_failures > 0 and policy.match_valid_seconds > 0;
    }

    /// A reference policy: five tries, a match good for thirty seconds.
    pub const reference: Policy = .{
        .max_consecutive_failures = 5,
        .match_valid_seconds = 30,
    };
};

/// The matcher's state across attempts.
///
/// The caller holds this because the decision depends on history: how many
/// failures have accrued, and whether a prior match is still fresh. Resetting
/// it happens only on a passcode entry, which is what clears a lockout.
pub const State = struct {
    consecutive_failures: u8 = 0,
    /// Seconds on the device clock of the last accepted match, or null if none.
    last_match_at_s: ?u32 = null,
    /// True once locked out, until the passcode clears it.
    locked_out: bool = false,

    /// Clears the failure count and lockout after a successful passcode entry.
    ///
    /// The biometric never clears its own lockout: only the stronger secret it
    /// falls back to can, which is what makes the fallback meaningful.
    pub fn clearAfterPasscode(state: *State) void {
        state.consecutive_failures = 0;
        state.locked_out = false;
    }
};

/// Judges an attempt.
///
/// The lockout is checked first: once the biometric is disabled, no score
/// reopens it, because a matcher that let a good-enough score end its own
/// lockout would have no lockout at all. A score at or above the threshold is
/// accepted and resets the failure count; one below increments it and, on
/// reaching the limit, locks out.
pub fn judge(
    policy: Policy,
    modality: Modality,
    state: *State,
    score: ScoreBasisPoints,
    now_s: u32,
) Outcome {
    // A locked-out biometric stays locked out whatever the score. Only the
    // passcode reopens it.
    if (state.locked_out) return .{ .refused = .locked_out };

    if (score >= modality.acceptanceThreshold()) {
        state.consecutive_failures = 0;
        state.last_match_at_s = now_s;
        return .{ .accepted = score };
    }

    state.consecutive_failures += 1;
    if (state.consecutive_failures >= policy.max_consecutive_failures) {
        state.locked_out = true;
        return .{ .refused = .locked_out };
    }
    return .{ .refused = .below_threshold };
}

/// Whether a prior accepted match may still authorize a follow-on operation.
///
/// A match is a proof of presence at a moment, not a standing permission. A
/// sensitive operation minutes later must not ride a match the person has
/// walked away from, so the match expires.
pub fn matchStillValid(policy: Policy, state: State, now_s: u32) bool {
    const matched_at = state.last_match_at_s orelse return false;
    if (now_s < matched_at) return false; // clock went backwards; do not trust
    return (now_s - matched_at) <= policy.match_valid_seconds;
}

const reference = Policy.reference;

test "the reference policy is valid" {
    try std.testing.expect(reference.isValid());
}

test "face is held to a higher bar than fingerprint" {
    // A photograph is easier to present than a copied fingertip, so a face match
    // must be more certain.
    try std.testing.expect(
        Modality.face.acceptanceThreshold() >
            Modality.fingerprint.acceptanceThreshold(),
    );
}

test "a confident match is accepted and resets the failure count" {
    var state: State = .{ .consecutive_failures = 3 };
    const outcome = judge(reference, .fingerprint, &state, 8_500, 1_000);
    try std.testing.expect(outcome.wasAccepted());
    try std.testing.expectEqual(@as(u8, 0), state.consecutive_failures);
    try std.testing.expectEqual(@as(?u32, 1_000), state.last_match_at_s);
}

test "a weak match is refused below threshold" {
    var state: State = .{};
    const outcome = judge(reference, .face, &state, 8_000, 1_000);
    try std.testing.expectEqual(Outcome{ .refused = .below_threshold }, outcome);
    try std.testing.expectEqual(@as(u8, 1), state.consecutive_failures);
}

test "enough failures lock out the biometric" {
    var state: State = .{};
    var last: Outcome = undefined;
    for (0..reference.max_consecutive_failures) |_| {
        last = judge(reference, .fingerprint, &state, 1_000, 1_000);
    }
    try std.testing.expectEqual(Outcome{ .refused = .locked_out }, last);
    try std.testing.expect(state.locked_out);
}

test "a lockout is not reopened by a good score" {
    var state: State = .{ .locked_out = true };
    // The whole safety net is that only the passcode reopens it; a matcher that
    // a good score could reopen would have no lockout at all.
    const outcome = judge(reference, .fingerprint, &state, full(), 1_000);
    try std.testing.expectEqual(Outcome{ .refused = .locked_out }, outcome);
}

test "only the passcode clears a lockout" {
    var state: State = .{ .locked_out = true, .consecutive_failures = 9 };
    state.clearAfterPasscode();
    try std.testing.expect(!state.locked_out);
    try std.testing.expectEqual(@as(u8, 0), state.consecutive_failures);

    // Now a match is judged again rather than refused outright.
    const outcome = judge(reference, .fingerprint, &state, 8_500, 1_000);
    try std.testing.expect(outcome.wasAccepted());
}

test "a fresh match authorizes a follow-on operation" {
    var state: State = .{};
    _ = judge(reference, .fingerprint, &state, 8_500, 1_000);
    try std.testing.expect(matchStillValid(reference, state, 1_020));
}

test "a stale match does not" {
    var state: State = .{};
    _ = judge(reference, .fingerprint, &state, 8_500, 1_000);
    // Past the validity window: a sensitive operation must not ride a match the
    // person has walked away from.
    try std.testing.expect(!matchStillValid(reference, state, 1_000 + reference.match_valid_seconds + 1));
}

test "no match at all is never valid" {
    const state: State = .{};
    try std.testing.expect(!matchStillValid(reference, state, 5_000));
}

test "a backwards clock invalidates a match rather than trusting it" {
    const state: State = .{ .last_match_at_s = 2_000 };
    // now before the match time means the clock moved; a match that predates now
    // by a negative amount is not something to trust.
    try std.testing.expect(!matchStillValid(reference, state, 1_000));
}

test "the failure count survives across attempts until a match or passcode" {
    var state: State = .{};
    _ = judge(reference, .face, &state, 1_000, 1_000);
    _ = judge(reference, .face, &state, 1_000, 1_001);
    try std.testing.expectEqual(@as(u8, 2), state.consecutive_failures);

    // A match resets it.
    _ = judge(reference, .face, &state, 9_500, 1_002);
    try std.testing.expectEqual(@as(u8, 0), state.consecutive_failures);
}

fn full() ScoreBasisPoints {
    return 10_000;
}
