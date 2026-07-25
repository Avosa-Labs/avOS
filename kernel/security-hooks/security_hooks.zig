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
const device_policy = @import("../device-policy/device_policy.zig");

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

/// A real privileged operation run through the pipeline: accessing a device.
///
/// This is the pipeline wired to something, rather than only to a test harness.
/// Authentication gates on the caller being known; authorization is the device
/// policy's own decision; state is the target being ready; performing an access
/// that captures discharges the capture obligation, which lights the indicator;
/// and audit always runs. A denial at any stage stops the operation and is still
/// recorded, so the ordered-mediation guarantee protects a concrete access.
pub const DeviceAccess = struct {
    authenticated: bool,
    class: device_policy.DeviceClass,
    access: device_policy.Access,
    grant: device_policy.Grant,
    situation: device_policy.Situation,
    target_ready: bool,
    indicator: *device_policy.Indicator,

    // Filled as the pipeline runs.
    allowance: ?device_policy.Allowance = null,
    capture: ?device_policy.ActiveCapture = null,
    audited: ?Outcome = null,

    fn decide(operation: *DeviceAccess, stage: Stage) Verdict {
        return switch (stage) {
            .authenticate => if (operation.authenticated) .proceed else .refuse,
            .authorize => {
                const decision = device_policy.decide(operation.class, operation.access, operation.grant, operation.situation);
                switch (decision) {
                    .allow => |allowance| {
                        operation.allowance = allowance;
                        return .proceed;
                    },
                    .deny => return .refuse,
                }
            },
            .check_state => if (operation.target_ready) .proceed else .refuse,
            .perform => {
                // A capture access lights the indicator here, through the
                // obligation, so the light is on before any sensing begins.
                if (operation.allowance) |allowance| {
                    switch (allowance) {
                        .capture => |obligation| operation.capture = obligation.begin(operation.indicator),
                        .no_capture => {},
                    }
                }
                return .proceed;
            },
            .audit => .proceed,
        };
    }

    fn record(operation: *DeviceAccess, outcome: Outcome) void {
        operation.audited = outcome;
    }

    /// Runs the access through the ordered pipeline and returns what happened.
    pub fn perform(operation: *DeviceAccess) Outcome {
        return Pipeline(DeviceAccess).run(operation, decide, record);
    }
};

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

fn cameraStreamGrant() device_policy.Grant {
    var classes = std.EnumSet(device_policy.DeviceClass).initEmpty();
    classes.insert(.camera);
    var accesses = std.EnumSet(device_policy.Access).initEmpty();
    accesses.insert(.stream);
    return .{ .classes = classes, .accesses = accesses };
}

test "an authorized camera stream runs every stage and lights the indicator" {
    var indicator: device_policy.Indicator = .{};
    var operation: DeviceAccess = .{
        .authenticated = true,
        .class = .camera,
        .access = .stream,
        .grant = cameraStreamGrant(),
        .situation = .{ .person_present = true },
        .target_ready = true,
        .indicator = &indicator,
    };

    const outcome = operation.perform();
    try std.testing.expect(outcome.wasCompleted());
    // Performing the capture lit the indicator through the obligation.
    try std.testing.expect(indicator.isLit(.camera));
    try std.testing.expect(operation.capture != null);
    // Audit ran with the completed outcome.
    try std.testing.expect(operation.audited.?.wasCompleted());
}

test "an unauthenticated access refuses at the first stage and still audits" {
    var indicator: device_policy.Indicator = .{};
    var operation: DeviceAccess = .{
        .authenticated = false,
        .class = .camera,
        .access = .stream,
        .grant = cameraStreamGrant(),
        .situation = .{ .person_present = true },
        .target_ready = true,
        .indicator = &indicator,
    };

    const outcome = operation.perform();
    try std.testing.expectEqual(Outcome{ .refused_at = .authenticate }, outcome);
    try std.testing.expect(!indicator.isLit(.camera));
    try std.testing.expectEqual(Outcome{ .refused_at = .authenticate }, operation.audited.?);
}

test "an access the device policy denies refuses at authorize" {
    var indicator: device_policy.Indicator = .{};
    // A grant for the camera but not for streaming: authorize denies.
    var classes = std.EnumSet(device_policy.DeviceClass).initEmpty();
    classes.insert(.camera);
    var operation: DeviceAccess = .{
        .authenticated = true,
        .class = .camera,
        .access = .stream,
        .grant = .{ .classes = classes, .accesses = std.EnumSet(device_policy.Access).initEmpty() },
        .situation = .{ .person_present = true },
        .target_ready = true,
        .indicator = &indicator,
    };

    const outcome = operation.perform();
    try std.testing.expectEqual(Outcome{ .refused_at = .authorize }, outcome);
    try std.testing.expect(!indicator.isLit(.camera));
}

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
