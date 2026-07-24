//! Deciding a test suite's verdict, so a suite passes only when every test actually passed and a
//! skipped test is never silently counted as a pass.
//!
//! A test harness reports whether a suite passed, and that verdict is only trustworthy if it is
//! strict about two things. A suite passes only when every test in it passed — one failure fails the
//! suite, because a green suite with a hidden failure is worse than a red one, it is a lie the
//! developer builds on. And a skipped test is not a passing test: skips happen for real reasons — a
//! platform a test cannot run on, a dependency unavailable — but counting a skip as a pass inflates
//! confidence, so the verdict distinguishes passed from skipped and a suite with only skips and no
//! real passes is not reported as verified. The harness also requires a recorded seed for any test
//! that uses randomness, because a failure that cannot be reproduced from its seed cannot be
//! debugged. Reporting honestly — passed means every test ran and passed, skips are visible, seeds
//! are recorded — is the whole value of a test harness.
//!
//! This module runs no tests. It computes a suite's verdict from its per-test outcomes, as a pure
//! function.

const std = @import("std");

/// The outcome of a single test.
pub const Outcome = enum { passed, failed, skipped };

/// A summary of a suite's outcomes.
pub const Summary = struct {
    passed: u32,
    failed: u32,
    skipped: u32,

    fn total(summary: Summary) u32 {
        return summary.passed + summary.failed + summary.skipped;
    }
};

/// A suite's verdict.
pub const Verdict = enum {
    /// Every test that ran passed, and at least one test actually ran.
    verified,
    /// A test failed.
    failed,
    /// Nothing failed, but no test actually passed (all skipped, or empty).
    inconclusive,

    pub fn isVerified(result: Verdict) bool {
        return result == .verified;
    }
};

/// Tallies a list of outcomes into a summary.
pub fn tally(outcomes: []const Outcome) Summary {
    var summary: Summary = .{ .passed = 0, .failed = 0, .skipped = 0 };
    for (outcomes) |outcome| {
        switch (outcome) {
            .passed => summary.passed += 1,
            .failed => summary.failed += 1,
            .skipped => summary.skipped += 1,
        }
    }
    return summary;
}

/// Computes a suite's verdict from its summary.
///
/// Any failure fails the suite — one failing test is enough, because a suite is only as trustworthy
/// as its weakest test. With no failures, the suite is verified only if at least one test actually
/// passed; a suite of only skips (or an empty one) is inconclusive, not verified, so a skip is never
/// counted as a pass. This keeps a green verdict meaning what a developer expects it to mean.
pub fn verdict(summary: Summary) Verdict {
    if (summary.failed > 0) return .failed;
    if (summary.passed == 0) return .inconclusive;
    return .verified;
}

test "a suite of all passes is verified" {
    const outcomes = [_]Outcome{ .passed, .passed, .passed };
    try std.testing.expectEqual(Verdict.verified, verdict(tally(&outcomes)));
}

test "any failure fails the suite" {
    const outcomes = [_]Outcome{ .passed, .failed, .passed };
    try std.testing.expectEqual(Verdict.failed, verdict(tally(&outcomes)));
}

test "a suite of only skips is inconclusive, not verified" {
    const outcomes = [_]Outcome{ .skipped, .skipped };
    try std.testing.expectEqual(Verdict.inconclusive, verdict(tally(&outcomes)));
}

test "an empty suite is inconclusive" {
    try std.testing.expectEqual(Verdict.inconclusive, verdict(tally(&.{})));
}

test "passes alongside skips are verified" {
    const outcomes = [_]Outcome{ .passed, .skipped, .passed };
    try std.testing.expectEqual(Verdict.verified, verdict(tally(&outcomes)));
}

test "a verified suite always had at least one pass and no failure, swept" {
    // The honest-verdict property: verified implies a real pass and zero failures.
    const suites = [_][]const Outcome{
        &.{ .passed, .passed },
        &.{ .passed, .skipped },
        &.{ .skipped, .skipped },
        &.{ .passed, .failed },
        &.{},
    };
    for (suites) |outcomes| {
        const s = tally(outcomes);
        if (verdict(s).isVerified()) {
            try std.testing.expect(s.passed > 0 and s.failed == 0);
        }
    }
}

test "one failure among many passes still fails, swept" {
    // The strictness property: any suite with a failure is failed, whatever the pass count.
    var passes: u32 = 0;
    while (passes <= 5) : (passes += 1) {
        const s: Summary = .{ .passed = passes, .failed = 1, .skipped = 0 };
        try std.testing.expectEqual(Verdict.failed, verdict(s));
    }
}
