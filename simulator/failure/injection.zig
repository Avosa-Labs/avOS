//! Deciding whether an injected fault fires at a given step, so the simulator can exercise failure
//! paths deterministically — a declared fault occurs at exactly its scheduled step and nowhere else.
//!
//! Recovery, rollback, and fail-closed behaviour only mean something if they are tested against actual
//! failures, and the simulator produces those failures on purpose rather than waiting for them to
//! happen. A fault is declared as part of a scenario: this kind of failure, at this simulated step. For
//! the test to be evidence, the fault must be as reproducible as everything else — it fires at the
//! scheduled step on every run, and it does not fire at any other step, so the behaviour under failure
//! is a fixed, replayable thing rather than an intermittent surprise. A fault scheduled for a step in
//! the past does not retroactively fire, and one scheduled for the future does not fire early; only the
//! exact match triggers. Deterministic fault timing is what lets a recovery test assert "given a crash
//! precisely here, the system recovers thus" and have that assertion hold identically every time.
//!
//! This module fails nothing. It decides whether a declared fault fires at the current step, from the
//! fault's scheduled step and the current step, as a pure function.

const std = @import("std");

/// A fault the scenario declared: a kind of failure scheduled for a specific simulated step.
pub const Fault = struct {
    /// The simulated step at which this fault is scheduled to fire.
    at_step: u64,
};

/// Whether a declared fault fires at the current step.
///
/// The fault fires exactly when the current step equals its scheduled step — not before, not after.
/// This makes the injected failure occur at one deterministic point, so a scenario replayed sees the
/// fault at the identical moment every run.
pub fn fires(fault: Fault, current_step: u64) bool {
    return fault.at_step == current_step;
}

test "a fault fires at its scheduled step" {
    try std.testing.expect(fires(.{ .at_step = 4 }, 4));
}

test "a fault does not fire before or after its step" {
    try std.testing.expect(!fires(.{ .at_step = 4 }, 3));
    try std.testing.expect(!fires(.{ .at_step = 4 }, 5));
}

test "a fault fires at exactly one step, swept" {
    // The deterministic-timing property: across a run of steps, the fault fires only at its scheduled
    // step, exactly once.
    const fault = Fault{ .at_step = 6 };
    var count: u32 = 0;
    var step: u64 = 0;
    while (step <= 12) : (step += 1) {
        if (fires(fault, step)) {
            count += 1;
            try std.testing.expectEqual(@as(u64, 6), step);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), count);
}
