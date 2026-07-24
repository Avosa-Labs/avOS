//! Compiling a validated plan into an executable task graph, refusing any step whose
//! authority the agent does not hold, so a plan can never grant itself power the
//! agent was denied.
//!
//! A plan says what to do; compiling it into a runnable task graph is where each step
//! is bound to the authority it will run under. That binding is a security boundary,
//! because a model wrote the plan, and a model asked to accomplish a goal will propose
//! whatever step accomplishes it — including one that needs authority the agent was
//! never granted. If the compiler simply emitted every step as runnable, the plan
//! would have escalated the agent's privilege merely by naming a more powerful step.
//! So compilation checks every step's required authority against what the agent holds,
//! and a single step that exceeds the grant fails the whole compilation rather than
//! being emitted and refused later mid-run, when partial effects may already have
//! happened. A plan compiles only if every step it contains is one the agent could
//! lawfully perform.
//!
//! This module runs no graph. It decides whether a plan's steps all fall within the
//! agent's authority and emits the count of runnable steps, as a pure function over
//! the plan and the grant.

const std = @import("std");

/// The coarse authority classes a step may require, matching the agent host's
/// envelope so a step is checked against the same grant the agent was admitted with.
pub const Class = enum { read, local_write, network, consequential };

/// A set of authority classes.
pub const Authority = std.EnumSet(Class);

/// One step of a plan to compile.
pub const Step = struct {
    /// The authority classes this step needs to run.
    requires: Authority,
};

/// Why compilation failed.
pub const Failure = struct {
    /// The index of the first step that exceeded the agent's authority.
    step_index: usize,
};

/// The compilation result.
pub const Result = union(enum) {
    /// The plan compiled; this many steps are runnable.
    compiled: usize,
    /// A step exceeded the agent's authority; the plan is refused.
    refused: Failure,

    pub fn ok(result: Result) bool {
        return result == .compiled;
    }
};

/// Compiles a plan against the agent's authority.
///
/// Every step's required authority must be a subset of the agent's grant. The steps
/// are checked in order, and the first that requires a class the agent lacks fails the
/// whole compilation, naming that step — because emitting a partial graph and refusing
/// the bad step at run time could leave earlier steps' effects already applied. A plan
/// whose every step is within the grant compiles, and the count of steps is returned.
pub fn compile(steps: []const Step, agent_authority: Authority) Result {
    for (steps, 0..) |step, index| {
        if (!step.requires.subsetOf(agent_authority)) {
            return .{ .refused = .{ .step_index = index } };
        }
    }
    return .{ .compiled = steps.len };
}

fn authorityOf(classes: []const Class) Authority {
    var authority: Authority = .initEmpty();
    for (classes) |class| authority.insert(class);
    return authority;
}

fn stepOf(classes: []const Class) Step {
    return .{ .requires = authorityOf(classes) };
}

test "a plan whose steps are all within authority compiles" {
    const agent = authorityOf(&.{ .read, .local_write, .network });
    const steps = [_]Step{
        stepOf(&.{.read}),
        stepOf(&.{ .read, .local_write }),
        stepOf(&.{.network}),
    };
    try std.testing.expectEqual(Result{ .compiled = 3 }, compile(&steps, agent));
}

test "a step exceeding the agent's authority refuses the plan" {
    const agent = authorityOf(&.{ .read, .local_write });
    const steps = [_]Step{
        stepOf(&.{.read}),
        stepOf(&.{.consequential}), // agent lacks consequential
        stepOf(&.{.read}),
    };
    try std.testing.expectEqual(Result{ .refused = .{ .step_index = 1 } }, compile(&steps, agent));
}

test "the first exceeding step is the one named" {
    const agent = authorityOf(&.{.read});
    const steps = [_]Step{
        stepOf(&.{.network}), // first violation
        stepOf(&.{.consequential}),
    };
    try std.testing.expectEqual(Result{ .refused = .{ .step_index = 0 } }, compile(&steps, agent));
}

test "an empty plan compiles to zero steps" {
    try std.testing.expectEqual(Result{ .compiled = 0 }, compile(&.{}, authorityOf(&.{.read})));
}

test "a step requiring exactly the agent's authority is allowed" {
    const classes = [_]Class{ .read, .network };
    const agent = authorityOf(&classes);
    const steps = [_]Step{stepOf(&classes)};
    try std.testing.expect(compile(&steps, agent).ok());
}

test "no plan compiles with a step outside the agent's authority, swept" {
    // The no-escalation property: whenever a plan compiles, every step's required
    // authority is a subset of the agent's grant.
    const agent = authorityOf(&.{ .read, .local_write });
    const step_sets = [_][]const Class{
        &.{.read}, &.{ .read, .local_write }, &.{.network}, &.{.consequential},
    };
    for (step_sets) |a| {
        for (step_sets) |b| {
            const steps = [_]Step{ stepOf(a), stepOf(b) };
            if (compile(&steps, agent).ok()) {
                for (steps) |step| try std.testing.expect(step.requires.subsetOf(agent));
            }
        }
    }
}
