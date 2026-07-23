//! Sequencing the steps a device takes to bring itself back after an
//! interruption, and knowing when to stop trying.
//!
//! Recovery is several steps that must happen in order and must each be allowed
//! to fail without leaving the device worse off. Replay the journal to rebuild
//! state; verify the slots so the running image is one that was committed;
//! reconcile any update that was in flight. If a step fails, the device does not
//! silently continue on partial state — it either falls back to a safe posture
//! it can operate in, or, when nothing safe remains, stops and says so rather
//! than pretending to have recovered.
//!
//! This module is the coordinator, not the steps. The steps live where their
//! data does — the journal replays itself, the updater verifies its slots. What
//! is centralized here is the order, the decision after each outcome, and the
//! guarantee that the sequence has a defined end for every combination of
//! results, so a device never loops trying to recover from something it cannot.

const std = @import("std");

/// A recovery step, in the order it runs.
///
/// The order is fixed and meaningful: state must be rebuilt before the image can
/// be judged against it, and the image must be settled before an in-flight
/// update is reconciled, or the reconciliation would act on a slot the device
/// has not yet decided to trust.
pub const Step = enum(u8) {
    /// Rebuild control-plane state by replaying the durable journal.
    replay_journal = 0,
    /// Verify each boot slot holds an image that was committed, not a partial
    /// write left by a crash.
    verify_slots = 1,
    /// Reconcile an update that was in flight when the interruption happened.
    reconcile_update = 2,

    pub const count = std.enums.values(Step).len;

    pub fn next(step: Step) ?Step {
        return std.enums.fromInt(Step, @intFromEnum(step) + 1);
    }
};

/// How a step turned out.
pub const StepOutcome = enum {
    /// The step completed and its result is trustworthy.
    recovered,
    /// The step could not complete, but the device can continue in a reduced
    /// but safe posture — degraded, not broken.
    degraded,
    /// The step failed in a way that leaves no safe posture. Recovery cannot
    /// continue.
    unrecoverable,
};

/// What the coordinator decides after a step.
pub const Decision = enum {
    /// Run the next step.
    continue_recovery,
    /// Stop here, in a safe reduced posture the device can operate in. Some
    /// function is lost but the device is usable and honest about it.
    finish_degraded,
    /// Stop here; the device cannot bring itself back and must hand off to a
    /// higher recovery (a recovery image, a support flow) rather than running on
    /// state it does not trust.
    halt,
};

/// Decides what to do after a step's outcome.
///
/// A recovered step continues to the next, and continues to completion when the
/// last step recovers. A degraded step still lets recovery proceed — a later
/// step may recover fully — but the run as a whole finishes degraded, because a
/// device that lost something during recovery must not report full health. An
/// unrecoverable step halts immediately, whatever came before, because there is
/// no safe way to continue past it.
pub fn decideAfter(step: Step, outcome: StepOutcome, any_prior_degradation: bool) Decision {
    return switch (outcome) {
        .unrecoverable => .halt,
        .degraded => if (step.next() == null) .finish_degraded else .continue_recovery,
        .recovered => if (step.next() == null)
            (if (any_prior_degradation) .finish_degraded else .continue_recovery)
        else
            .continue_recovery,
    };
}

/// What a whole recovery run concluded.
pub const Result = enum {
    /// Every step recovered; the device is fully back.
    fully_recovered,
    /// The device is usable but lost something; it must say so.
    degraded,
    /// The device could not recover itself.
    halted,

    pub fn isUsable(result: Result) bool {
        return result != .halted;
    }
};

/// Runs the recovery sequence, given a function that performs each step.
///
/// The coordinator drives the fixed order, applies the decision after each step,
/// and returns the run's conclusion. `perform` does the real work for a step and
/// reports how it went; this guarantees the ordering, the stop conditions, and
/// that every combination of outcomes reaches a defined end.
pub fn Coordinator(comptime Context: type) type {
    return struct {
        pub const PerformFn = *const fn (context: *Context, step: Step) StepOutcome;

        /// Runs recovery to a conclusion.
        pub fn run(context: *Context, perform: PerformFn) Result {
            var degraded = false;
            var step: Step = .replay_journal;
            while (true) {
                const outcome = perform(context, step);
                if (outcome == .degraded) degraded = true;

                switch (decideAfter(step, outcome, degraded)) {
                    .halt => return .halted,
                    .finish_degraded => return .degraded,
                    .continue_recovery => {
                        step = step.next() orelse {
                            // The last step recovered with no prior degradation:
                            // fully back.
                            return if (degraded) .degraded else .fully_recovered;
                        };
                    },
                }
            }
        }
    };
}

/// Drives a fixed sequence of outcomes, for tests.
const Script = struct {
    outcomes: [Step.count]StepOutcome,
    performed: [Step.count]bool = @splat(false),

    fn perform(script: *Script, step: Step) StepOutcome {
        script.performed[@intFromEnum(step)] = true;
        return script.outcomes[@intFromEnum(step)];
    }
};

const ScriptedCoordinator = Coordinator(Script);

test "the step order is fixed and total" {
    try std.testing.expectEqual(Step.verify_slots, Step.replay_journal.next().?);
    try std.testing.expectEqual(Step.reconcile_update, Step.verify_slots.next().?);
    try std.testing.expectEqual(@as(?Step, null), Step.reconcile_update.next());
}

test "every step recovering is a full recovery" {
    var script: Script = .{ .outcomes = .{ .recovered, .recovered, .recovered } };
    try std.testing.expectEqual(Result.fully_recovered, ScriptedCoordinator.run(&script, Script.perform));
    // Every step actually ran.
    for (script.performed) |ran| try std.testing.expect(ran);
}

test "an unrecoverable step halts immediately and skips the rest" {
    var script: Script = .{ .outcomes = .{ .recovered, .unrecoverable, .recovered } };
    try std.testing.expectEqual(Result.halted, ScriptedCoordinator.run(&script, Script.perform));

    // The step after the failure never ran: the device did not continue on
    // untrusted state.
    try std.testing.expect(script.performed[@intFromEnum(Step.replay_journal)]);
    try std.testing.expect(script.performed[@intFromEnum(Step.verify_slots)]);
    try std.testing.expect(!script.performed[@intFromEnum(Step.reconcile_update)]);
}

test "a degraded step lets recovery finish but marks the whole run degraded" {
    // The journal replayed only partially, but the later steps recover: the
    // device is usable, and honest that it lost something.
    var script: Script = .{ .outcomes = .{ .degraded, .recovered, .recovered } };
    try std.testing.expectEqual(Result.degraded, ScriptedCoordinator.run(&script, Script.perform));
    for (script.performed) |ran| try std.testing.expect(ran);
}

test "a degrade on the last step finishes degraded" {
    var script: Script = .{ .outcomes = .{ .recovered, .recovered, .degraded } };
    try std.testing.expectEqual(Result.degraded, ScriptedCoordinator.run(&script, Script.perform));
}

test "the first step being unrecoverable halts before anything else runs" {
    var script: Script = .{ .outcomes = .{ .unrecoverable, .recovered, .recovered } };
    try std.testing.expectEqual(Result.halted, ScriptedCoordinator.run(&script, Script.perform));
    try std.testing.expect(!script.performed[@intFromEnum(Step.verify_slots)]);
}

test "every combination of outcomes reaches a defined end" {
    // The guarantee the coordinator exists for: no sequence of results loops or
    // hangs. Swept across all outcome combinations for all steps.
    const outcomes = [_]StepOutcome{ .recovered, .degraded, .unrecoverable };
    for (outcomes) |a| {
        for (outcomes) |b| {
            for (outcomes) |c| {
                var script: Script = .{ .outcomes = .{ a, b, c } };
                const result = ScriptedCoordinator.run(&script, Script.perform);
                // Reaching here at all means it terminated; the result is one of
                // the three defined ends.
                try std.testing.expect(result == .fully_recovered or
                    result == .degraded or
                    result == .halted);
            }
        }
    }
}

test "a halted device is not usable and a degraded one is" {
    try std.testing.expect(!Result.halted.isUsable());
    try std.testing.expect(Result.degraded.isUsable());
    try std.testing.expect(Result.fully_recovered.isUsable());
}

test "an unrecoverable step always halts, whatever preceded it" {
    // Even after a degrade, an unrecoverable step halts rather than finishing
    // degraded: there is no safe posture past it.
    try std.testing.expectEqual(
        Decision.halt,
        decideAfter(.verify_slots, .unrecoverable, true),
    );
}

test "recovering the last step after an earlier degrade still finishes degraded" {
    // A recovered final step does not erase an earlier loss; the run is degraded.
    try std.testing.expectEqual(
        Decision.finish_degraded,
        decideAfter(.reconcile_update, .recovered, true),
    );
    // With no prior degradation, the same step continues to a full recovery.
    try std.testing.expectEqual(
        Decision.continue_recovery,
        decideAfter(.reconcile_update, .recovered, false),
    );
}
