//! Turning a goal into a bounded plan of steps, and refusing a plan that would
//! run away.
//!
//! An agent given a goal produces a plan: a sequence of steps, some depending on
//! others, that together accomplish it. The danger is not a bad step; it is an
//! unbounded one — a plan that spawns a step that spawns a step, a cycle where A
//! waits on B and B waits on A, a plan so deep or so wide that carrying it out
//! costs more than the goal is worth. A model proposes plans, and a model asked
//! to be thorough will happily propose one that never terminates. So a plan is
//! not executed because it was produced; it is validated first, and a plan that
//! could not finish is refused before a single step runs.
//!
//! This module holds the plan structure and that validation. It executes
//! nothing; it checks that a proposed plan is a finite directed acyclic graph
//! within the bounds an agent's budget allows, and reports which property failed
//! so the agent can replan rather than being told only "invalid". A plan that
//! passes can be run to completion; that is the guarantee validation buys.

const std = @import("std");

/// The most steps a plan may contain.
///
/// A ceiling, because a plan is carried out under a budget and an unbounded plan
/// is an unbounded cost. A goal that genuinely needs more steps is decomposed
/// into sub-goals, each its own bounded plan.
pub const max_steps: usize = 64;

/// The deepest a dependency chain may run.
///
/// Depth is latency: each level must finish before the next begins, so a plan
/// twenty deep takes twenty sequential stages however wide it is. Bounding depth
/// bounds how long a plan can take even when every step is fast.
pub const max_depth: usize = 16;

/// One step in a plan.
pub const Step = struct {
    /// Indices of the steps this one depends on. It may run only once all of
    /// them have completed. An empty list is a root step, runnable immediately.
    depends_on: []const usize,
};

pub const Error = error{
    /// The plan has more steps than the ceiling allows.
    TooManySteps,
    /// A step depends on an index that is not a step in the plan.
    DanglingDependency,
    /// A step depends on itself, directly or through a cycle. A cyclic plan
    /// never completes.
    CyclicDependency,
    /// A step depends on one that comes later, which a forward-only executor
    /// cannot satisfy and which is usually the first sign of a cycle.
    ForwardDependency,
    /// The dependency chain is deeper than the ceiling allows.
    TooDeep,
};

/// A proposed plan.
pub const Plan = struct {
    steps: []const Step,

    /// Validates the plan, returning its depth if it is sound.
    ///
    /// Checks, in order: the step count is within bounds; every dependency names
    /// a real earlier step; and the resulting graph is acyclic and within the
    /// depth ceiling. Requiring dependencies to point backward makes the plan a
    /// topological order by construction, so an executor can run it front to
    /// back and a cycle is impossible to express — the one class of runaway plan
    /// that is caught by shape rather than by search.
    pub fn validate(plan: Plan) Error!usize {
        if (plan.steps.len > max_steps) return error.TooManySteps;

        var depth: [max_steps]usize = undefined;
        var max_observed: usize = 0;

        for (plan.steps, 0..) |current, index| {
            var step_depth: usize = 0;
            for (current.depends_on) |dependency| {
                if (dependency >= plan.steps.len) return error.DanglingDependency;
                if (dependency == index) return error.CyclicDependency;
                // A dependency must point to an earlier step. This makes the
                // step list a valid execution order and rules out cycles: a
                // cycle would require some step to depend on a later one.
                if (dependency > index) return error.ForwardDependency;
                step_depth = @max(step_depth, depth[dependency] + 1);
            }
            depth[index] = step_depth;
            max_observed = @max(max_observed, step_depth);
        }

        // Depth is the longest chain: zero for an empty plan, otherwise one more
        // than the deepest dependency observed.
        const plan_depth = if (plan.steps.len == 0) 0 else max_observed + 1;
        if (plan_depth > max_depth) return error.TooDeep;
        return plan_depth;
    }

    /// Whether the plan is sound.
    pub fn isValid(plan: Plan) bool {
        _ = plan.validate() catch return false;
        return true;
    }

    /// The steps that can run first: those with no dependencies. An executor
    /// starts here.
    pub fn rootSteps(plan: Plan, into: []usize) []const usize {
        var count: usize = 0;
        for (plan.steps, 0..) |current, index| {
            if (current.depends_on.len == 0 and count < into.len) {
                into[count] = index;
                count += 1;
            }
        }
        return into[0..count];
    }
};

fn step(depends_on: []const usize) Step {
    return .{ .depends_on = depends_on };
}

test "a linear plan validates with depth equal to its length" {
    // Each step depends on the previous: a chain of four is four deep.
    const steps = [_]Step{
        step(&.{}),
        step(&.{0}),
        step(&.{1}),
        step(&.{2}),
    };
    const plan: Plan = .{ .steps = &steps };
    try std.testing.expectEqual(@as(usize, 4), try plan.validate());
}

test "a wide plan is shallow" {
    // Four independent steps: depth one, however many there are.
    const steps = [_]Step{ step(&.{}), step(&.{}), step(&.{}), step(&.{}) };
    const plan: Plan = .{ .steps = &steps };
    try std.testing.expectEqual(@as(usize, 1), try plan.validate());
}

test "a diamond plan takes its longest path as depth" {
    // 0 -> 1, 0 -> 2, both -> 3: depth three, the longest chain.
    const steps = [_]Step{
        step(&.{}),
        step(&.{0}),
        step(&.{0}),
        step(&.{ 1, 2 }),
    };
    const plan: Plan = .{ .steps = &steps };
    try std.testing.expectEqual(@as(usize, 3), try plan.validate());
}

test "a dependency on a nonexistent step is caught" {
    const steps = [_]Step{ step(&.{}), step(&.{5}) };
    try std.testing.expectError(error.DanglingDependency, (Plan{ .steps = &steps }).validate());
}

test "a step depending on itself is refused" {
    const steps = [_]Step{step(&.{0})};
    try std.testing.expectError(error.CyclicDependency, (Plan{ .steps = &steps }).validate());
}

test "a forward dependency is refused, ruling out cycles by shape" {
    // Step 0 depends on step 1, which comes later: an executor running front to
    // back could never satisfy it, and it is the shape a cycle would take.
    const steps = [_]Step{ step(&.{1}), step(&.{}) };
    try std.testing.expectError(error.ForwardDependency, (Plan{ .steps = &steps }).validate());
}

test "a plan over the step ceiling is refused" {
    var steps: [max_steps + 1]Step = undefined;
    for (&steps) |*s| s.* = step(&.{});
    try std.testing.expectError(error.TooManySteps, (Plan{ .steps = &steps }).validate());
}

test "a plan deeper than the ceiling is refused" {
    // A chain longer than max_depth: each depends on the previous.
    var deps: [max_depth + 1][1]usize = undefined;
    var steps: [max_depth + 1]Step = undefined;
    steps[0] = step(&.{});
    for (1..max_depth + 1) |index| {
        deps[index] = .{index - 1};
        steps[index] = step(&deps[index]);
    }
    try std.testing.expectError(error.TooDeep, (Plan{ .steps = &steps }).validate());
}

test "a plan exactly at the depth ceiling is allowed" {
    var deps: [max_depth][1]usize = undefined;
    var steps: [max_depth]Step = undefined;
    steps[0] = step(&.{});
    for (1..max_depth) |index| {
        deps[index] = .{index - 1};
        steps[index] = step(&deps[index]);
    }
    try std.testing.expectEqual(max_depth, try (Plan{ .steps = &steps }).validate());
}

test "root steps are those with no dependencies" {
    const steps = [_]Step{
        step(&.{}),
        step(&.{0}),
        step(&.{}),
        step(&.{ 0, 2 }),
    };
    const plan: Plan = .{ .steps = &steps };
    var buffer: [max_steps]usize = undefined;
    const roots = plan.rootSteps(&buffer);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, roots);
}

test "an empty plan is trivially valid with zero depth" {
    const plan: Plan = .{ .steps = &.{} };
    try std.testing.expectEqual(@as(usize, 0), try plan.validate());
    try std.testing.expect(plan.isValid());
}

test "a validated plan is a runnable topological order" {
    // The guarantee validation buys: because every dependency points backward,
    // running the steps in index order never reaches a step whose dependencies
    // are unmet. Checked by confirming each step's dependencies precede it.
    const steps = [_]Step{
        step(&.{}),
        step(&.{0}),
        step(&.{0}),
        step(&.{ 1, 2 }),
    };
    const plan: Plan = .{ .steps = &steps };
    try std.testing.expect(plan.isValid());
    for (plan.steps, 0..) |current, index| {
        for (current.depends_on) |dependency| {
            try std.testing.expect(dependency < index);
        }
    }
}
