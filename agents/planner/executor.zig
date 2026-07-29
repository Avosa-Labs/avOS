//! Carrying out a validated plan, one step at a time — the agent's action loop.
//!
//! `planner.zig` proves a plan is a finite DAG whose dependencies point backward, so a forward walk
//! over its steps already respects every dependency: a step's prerequisites are all at lower indices,
//! and if any of them did not run the walk has already stopped there. This module is that walk. It
//! carries out each step through a caller-supplied runner — the bridge to the real, gated operation —
//! and stops at the first step that does not execute: a step held for a person to approve, denied, or
//! failed. Its dependents cannot run without it, so halting there is correct, and the caller learns
//! exactly which step paused the plan and why (an agent replans or waits for the approval rather than
//! being told only "stopped"). Each step is attempted at most once.
//!
//! Complexity: one pass over the steps, O(n) in the step count, with no per-step rescanning of the
//! dependency graph — the validated backward-pointing order is what buys that. It executes real work
//! only through the runner; the gating, holding, and recording live in the runner's frame, not here.

const std = @import("std");
const planner = @import("planner.zig");

/// How a single step ended when the agent tried to carry it out. Only `executed` lets the plan
/// advance; the rest each halt it (a person must approve a held step, a denied step is refused at the
/// gate, a failed step errored in the domain).
pub const StepOutcome = enum { executed, held, denied, failed };

/// The caller's bridge from a plan step to the real operation, gated and recorded by the frame the
/// runner wraps. The executor asks it to carry out step `index` and reads only whether it executed.
pub const StepRunner = struct {
    context: *anyopaque,
    run_fn: *const fn (context: *anyopaque, index: usize) StepOutcome,
};

/// What a run accomplished: how many steps executed, and — if it stopped short — which step halted it
/// and how. A run that reaches the end has `stopped_at == null`.
pub const Progress = struct {
    ran: usize = 0,
    stopped_at: ?usize = null,
    reason: ?StepOutcome = null,

    /// Whether every step ran.
    pub fn complete(progress: Progress) bool {
        return progress.stopped_at == null;
    }
};

/// Runs a validated plan in dependency order, stopping at the first step that does not execute.
/// O(n) over the steps: a single forward pass, because the plan's dependencies point backward and were
/// already checked by `planner.Plan.validate`, so index order is a valid execution order and no step's
/// dependencies need re-examining here. Attempts each step at most once.
pub fn run(plan: planner.Plan, runner: StepRunner) Progress {
    var ran: usize = 0;
    for (plan.steps, 0..) |_, index| {
        const outcome = runner.run_fn(runner.context, index);
        if (outcome != .executed) {
            return .{ .ran = ran, .stopped_at = index, .reason = outcome };
        }
        ran += 1;
    }
    return .{ .ran = ran };
}

// --- Tests ---

const testing = std.testing;

/// A runner driven by a fixed outcome per step, counting how many times each step was attempted so a
/// test can prove exactly-once.
const ScriptedRunner = struct {
    outcomes: []const StepOutcome,
    attempts: []usize,

    fn runStep(context: *anyopaque, index: usize) StepOutcome {
        const self: *ScriptedRunner = @ptrCast(@alignCast(context));
        self.attempts[index] += 1;
        return self.outcomes[index];
    }

    fn runner(self: *ScriptedRunner) StepRunner {
        return .{ .context = self, .run_fn = runStep };
    }
};

test "a plan whose every step executes runs to completion, each step once" {
    var attempts = [_]usize{0} ** 3;
    const outcomes = [_]StepOutcome{ .executed, .executed, .executed };
    var scripted = ScriptedRunner{ .outcomes = &outcomes, .attempts = &attempts };

    var steps = [_]planner.Step{
        .{ .depends_on = &.{} },
        .{ .depends_on = &.{0} },
        .{ .depends_on = &.{1} },
    };
    const progress = run(.{ .steps = &steps }, scripted.runner());

    try testing.expect(progress.complete());
    try testing.expectEqual(@as(usize, 3), progress.ran);
    for (attempts) |a| try testing.expectEqual(@as(usize, 1), a); // exactly once
}

test "a held step halts the plan there, and its dependents never run" {
    var attempts = [_]usize{0} ** 3;
    const outcomes = [_]StepOutcome{ .executed, .held, .executed };
    var scripted = ScriptedRunner{ .outcomes = &outcomes, .attempts = &attempts };

    var steps = [_]planner.Step{
        .{ .depends_on = &.{} },
        .{ .depends_on = &.{0} },
        .{ .depends_on = &.{1} },
    };
    const progress = run(.{ .steps = &steps }, scripted.runner());

    try testing.expect(!progress.complete());
    try testing.expectEqual(@as(usize, 1), progress.ran); // only step 0 ran
    try testing.expectEqual(@as(usize, 1), progress.stopped_at.?);
    try testing.expectEqual(StepOutcome.held, progress.reason.?);
    // The dependent step 2 was never attempted.
    try testing.expectEqual(@as(usize, 1), attempts[0]);
    try testing.expectEqual(@as(usize, 1), attempts[1]);
    try testing.expectEqual(@as(usize, 0), attempts[2]);
}

test "a denied first step stops the plan immediately with nothing run" {
    var attempts = [_]usize{0} ** 2;
    const outcomes = [_]StepOutcome{ .denied, .executed };
    var scripted = ScriptedRunner{ .outcomes = &outcomes, .attempts = &attempts };

    var steps = [_]planner.Step{
        .{ .depends_on = &.{} },
        .{ .depends_on = &.{0} },
    };
    const progress = run(.{ .steps = &steps }, scripted.runner());

    try testing.expectEqual(@as(usize, 0), progress.ran);
    try testing.expectEqual(@as(usize, 0), progress.stopped_at.?);
    try testing.expectEqual(StepOutcome.denied, progress.reason.?);
    try testing.expectEqual(@as(usize, 0), attempts[1]);
}

test "an empty plan is trivially complete" {
    var scripted = ScriptedRunner{ .outcomes = &.{}, .attempts = &.{} };
    const progress = run(.{ .steps = &.{} }, scripted.runner());
    try testing.expect(progress.complete());
    try testing.expectEqual(@as(usize, 0), progress.ran);
}
