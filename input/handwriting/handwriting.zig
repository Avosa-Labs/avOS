//! Deciding whether a handwritten stroke is recognized confidently enough to commit, so a
//! clear character is inserted and an ambiguous one offers choices rather than guessing.
//!
//! Handwriting recognition turns a stroke into a character, and it is never certain — the
//! recognizer produces a best guess with a confidence, and often a second guess close
//! behind. How that confidence is handled decides whether the feature helps or fights the
//! person. When the top guess is clearly ahead — high confidence, and well clear of the
//! runner-up — it is committed directly, because pausing to confirm an obvious character is
//! friction. When the top guess is uncertain, or barely ahead of an alternative, committing
//! it would insert the wrong character as often as the right one, so instead the recognizer
//! offers the top candidates for the person to pick, which is faster than deleting a wrong
//! guess. The rule is to commit only when confident and clear, and to offer choices
//! otherwise — never to silently insert a low-confidence guess.
//!
//! This module recognizes no strokes. It decides whether to commit a recognition or offer
//! candidates, from the top guess's confidence and its margin over the next, as a pure
//! function.

const std = @import("std");

/// The minimum confidence, out of 100, the top guess must have to be committed directly.
pub const commit_confidence: u8 = 80;

/// The minimum margin, out of 100, the top guess must lead the runner-up by to be
/// committed. Even a high-confidence guess is not committed if a close alternative exists.
pub const commit_margin: u8 = 20;

/// A recognition result: the top guess and the runner-up.
pub const Result = struct {
    /// The confidence of the top guess, 0 to 100.
    top_confidence: u8,
    /// The confidence of the second-best guess, 0 to 100.
    runner_up_confidence: u8,
};

/// What to do with a recognition.
pub const Decision = enum {
    /// Commit the top guess directly.
    commit,
    /// Offer the top candidates for the person to choose from.
    offer_candidates,

    pub fn commits(decision: Decision) bool {
        return decision == .commit;
    }
};

/// Decides whether to commit a recognition or offer candidates.
///
/// The top guess is committed only when it is both confident on its own — at or above the
/// commit confidence — and clearly ahead of the runner-up by at least the commit margin. If
/// either fails — low confidence, or a close alternative — the recognition is uncertain and
/// candidates are offered instead, so a doubtful guess is never silently inserted.
pub fn decide(result: Result) Decision {
    if (result.top_confidence < commit_confidence) return .offer_candidates;
    const margin = result.top_confidence - @min(result.top_confidence, result.runner_up_confidence);
    if (margin < commit_margin) return .offer_candidates;
    return .commit;
}

fn makeResult(top: u8, runner_up: u8) Result {
    return .{ .top_confidence = top, .runner_up_confidence = runner_up };
}

test "a confident, clear recognition commits" {
    try std.testing.expectEqual(Decision.commit, decide(makeResult(95, 20)));
}

test "a low-confidence recognition offers candidates" {
    try std.testing.expectEqual(Decision.offer_candidates, decide(makeResult(60, 10)));
}

test "a confident but close recognition offers candidates" {
    // High top confidence, but the runner-up is close: too ambiguous to commit.
    try std.testing.expectEqual(Decision.offer_candidates, decide(makeResult(85, 75)));
}

test "the commit thresholds are inclusive" {
    // Exactly at the confidence and margin bounds commits.
    try std.testing.expectEqual(Decision.commit, decide(makeResult(commit_confidence, commit_confidence - commit_margin)));
}

test "no low-confidence guess is ever committed, swept" {
    // The no-silent-wrong-guess property: whenever a recognition commits, the top guess is
    // confident and clear.
    const confidences = [_]u8{ 40, 70, 80, 90, 100 };
    for (confidences) |top| {
        for (confidences) |runner| {
            if (runner > top) continue;
            if (decide(makeResult(top, runner)).commits()) {
                try std.testing.expect(top >= commit_confidence);
                try std.testing.expect(top - runner >= commit_margin);
            }
        }
    }
}
