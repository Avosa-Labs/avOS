//! The points a privileged operation must pass through, and the order it passes
//! them in.
//!
//! A security decision is not one check. It is a sequence: is the caller who
//! they claim, may they do this, is the thing they are acting on in a state that
//! allows it, and — whatever the answer — is the attempt recorded. This module
//! is where that sequence is fixed, so that no operation reaches its effect
//! having skipped a stage, and so the order is the same everywhere rather than
//! whatever each caller happened to write.
//!
//! The reason to make the sequence explicit is that the dangerous mediation bug
//! is not a check that returns the wrong answer. It is a check that was never
//! reached: an operation that authorized before it authenticated, or performed
//! before it authorized, or performed without recording. Each is invisible when
//! the stages are scattered across call sites and impossible when they are a
//! single ordered pipeline that refuses to advance past a stage that failed.
//!
//! This holds no policy of its own. Each stage is a decision the caller supplies
//! — the capability store authorizes, the device policy checks device state, the
//! ledger records. The hook layer guarantees only that they run, in order, and
//! that the audit stage runs whether the operation succeeded or was refused.

const std = @import("std");

/// The stages, in the order every privileged operation passes them.
///
/// The order is not a preference. Authentication must precede authorization
/// because you cannot decide what an unknown caller may do; authorization must
/// precede the state check because there is no point asking whether a device is
/// ready for an operation the caller may not perform; the effect comes last; and
/// audit is last of all because it must record the outcome, which does not exist
/// until the effect has been attempted or refused.
pub const Stage = enum(u8) {
    /// Establish who the caller is.
    authenticate = 0,
    /// Decide whether they may perform this operation.
    authorize = 1,
    /// Check that the target is in a state that allows the operation.
    check_state = 2,
    /// Perform the operation.
    perform = 3,
    /// Record what happened, whichever way it went.
    audit = 4,

    pub const count = std.enums.values(Stage).len;

    pub fn next(stage: Stage) ?Stage {
        return std.enums.fromInt(Stage, @intFromEnum(stage) + 1);
    }

    /// Whether this stage runs even when an earlier one refused.
    ///
    /// Only audit does. A refused operation that goes unrecorded is a refusal
    /// nobody can later see was attempted, which is exactly the attempt worth
    /// seeing.
    pub fn runsAfterRefusal(stage: Stage) bool {
        return stage == .audit;
    }
};

/// What a stage decided.
pub const Verdict = enum {
    /// The stage passed; the operation may advance.
    proceed,
    /// The stage refused; the operation stops, but audit still runs.
    refuse,
};

/// Why an operation was stopped, if it was.
pub const Outcome = union(enum) {
    /// The operation passed every stage and was performed and recorded.
    completed,
    /// A stage refused. Carries which one, so the refusal can be explained.
    refused_at: Stage,
    /// The pipeline itself was misused: a stage was run out of order, or the
    /// operation was driven past a refusal. A defect, not a policy outcome.
    misused,

    pub fn wasCompleted(outcome: Outcome) bool {
        return outcome == .completed;
    }
};

/// Runs one operation through the stages.
///
/// The caller provides a function that decides each stage; this drives them in
/// order, stops at the first refusal, and always runs audit. It is generic over
/// the caller's context so the real control plane and a test drive the identical
/// sequence.
///
/// `decide` is called once per stage that runs, in order, and returns a verdict.
/// `audit` is called exactly once, at the end, with the outcome so far, and its
/// own verdict is ignored: a security decision that could be cancelled by
/// failing to record it would not be recorded, which is the opposite of the
/// point.
pub fn Pipeline(comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const StageFn = *const fn (context: *Context, stage: Stage) Verdict;
        pub const AuditFn = *const fn (context: *Context, outcome: Outcome) void;

        /// Runs the operation and returns what happened.
        pub fn run(context: *Context, decide: StageFn, audit: AuditFn) Outcome {
            var refused_at: ?Stage = null;

            // Every stage before audit, in order, stopping at the first refusal.
            var stage: Stage = .authenticate;
            while (stage != .audit) : (stage = stage.next().?) {
                if (refused_at != null) break;
                if (decide(context, stage) == .refuse) refused_at = stage;
            }

            const outcome: Outcome = if (refused_at) |where|
                .{ .refused_at = where }
            else
                .completed;

            // Audit runs whichever way it went, and its verdict cannot change
            // the outcome: a refusal that went unrecorded would be a refusal
            // nobody can see was attempted.
            audit(context, outcome);
            return outcome;
        }
    };
}

/// Records which stages ran, in order, for a test to inspect.
const Trace = struct {
    ran: [Stage.count]Stage = undefined,
    count: usize = 0,
    /// The stage at which the recorded decision function refuses, if any.
    refuse_at: ?Stage = null,
    audited_outcome: ?Outcome = null,

    fn decide(trace: *Trace, stage: Stage) Verdict {
        trace.ran[trace.count] = stage;
        trace.count += 1;
        if (trace.refuse_at) |where| {
            if (where == stage) return .refuse;
        }
        return .proceed;
    }

    fn audit(trace: *Trace, outcome: Outcome) void {
        // Audit is recorded separately, so a test can see it ran even though it
        // is not one of the ordered stages above.
        trace.audited_outcome = outcome;
    }

    fn ranStages(trace: *const Trace) []const Stage {
        return trace.ran[0..trace.count];
    }
};

const TracePipeline = Pipeline(Trace);

test "the stage order is fixed and total" {
    // Each stage leads to exactly the next, and audit is last.
    try std.testing.expectEqual(Stage.authorize, Stage.authenticate.next().?);
    try std.testing.expectEqual(Stage.check_state, Stage.authorize.next().?);
    try std.testing.expectEqual(Stage.perform, Stage.check_state.next().?);
    try std.testing.expectEqual(Stage.audit, Stage.perform.next().?);
    try std.testing.expectEqual(@as(?Stage, null), Stage.audit.next());
}

test "a clean operation runs every stage in order and records completion" {
    var trace: Trace = .{};
    const outcome = TracePipeline.run(&trace, Trace.decide, Trace.audit);

    try std.testing.expect(outcome.wasCompleted());
    try std.testing.expectEqualSlices(Stage, &.{
        .authenticate,
        .authorize,
        .check_state,
        .perform,
    }, trace.ranStages());
    try std.testing.expectEqual(Outcome.completed, trace.audited_outcome.?);
}

test "authorization is never reached before authentication" {
    // Refusing at authentication must stop the operation there: you cannot
    // decide what an unknown caller may do.
    var trace: Trace = .{ .refuse_at = .authenticate };
    const outcome = TracePipeline.run(&trace, Trace.decide, Trace.audit);

    try std.testing.expectEqual(Outcome{ .refused_at = .authenticate }, outcome);
    try std.testing.expectEqualSlices(Stage, &.{.authenticate}, trace.ranStages());
}

test "the effect is never performed when authorization refuses" {
    // The bug this exists to prevent: performing before authorizing. A refusal
    // at authorize must mean perform never ran.
    var trace: Trace = .{ .refuse_at = .authorize };
    const outcome = TracePipeline.run(&trace, Trace.decide, Trace.audit);

    try std.testing.expectEqual(Outcome{ .refused_at = .authorize }, outcome);
    for (trace.ranStages()) |stage| {
        try std.testing.expect(stage != .perform);
    }
}

test "a state check refusal stops before the effect" {
    var trace: Trace = .{ .refuse_at = .check_state };
    const outcome = TracePipeline.run(&trace, Trace.decide, Trace.audit);

    try std.testing.expectEqual(Outcome{ .refused_at = .check_state }, outcome);
    try std.testing.expectEqualSlices(Stage, &.{
        .authenticate,
        .authorize,
        .check_state,
    }, trace.ranStages());
}

test "audit runs whether the operation completed or was refused" {
    // The one stage that always runs. A refused operation that went unrecorded
    // is an attempt nobody can later see was made.
    for ([_]?Stage{ null, .authenticate, .authorize, .check_state }) |refuse_at| {
        var trace: Trace = .{ .refuse_at = refuse_at };
        _ = TracePipeline.run(&trace, Trace.decide, Trace.audit);
        try std.testing.expect(trace.audited_outcome != null);
    }
}

test "audit records the outcome, including which stage refused" {
    var trace: Trace = .{ .refuse_at = .authorize };
    _ = TracePipeline.run(&trace, Trace.decide, Trace.audit);
    try std.testing.expectEqual(Outcome{ .refused_at = .authorize }, trace.audited_outcome.?);
}

test "only audit runs after a refusal" {
    for (std.enums.values(Stage)) |stage| {
        if (stage == .audit) {
            try std.testing.expect(stage.runsAfterRefusal());
        } else {
            try std.testing.expect(!stage.runsAfterRefusal());
        }
    }
}

test "the stages a caller could reach never skip one" {
    // Whatever stage a decision function refuses at, the stages that ran are a
    // prefix of the fixed order: 0, 1, ... k. Never a gap.
    for (std.enums.values(Stage)) |refuse_at| {
        if (refuse_at == .audit) continue;
        var trace: Trace = .{ .refuse_at = refuse_at };
        _ = TracePipeline.run(&trace, Trace.decide, Trace.audit);
        for (trace.ranStages(), 0..) |stage, index| {
            try std.testing.expectEqual(@as(u8, @intCast(index)), @intFromEnum(stage));
        }
    }
}
