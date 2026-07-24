//! Deciding which onboarding step comes next and whether setup is complete, so a person is
//! never dropped into the device with a required step skipped or blocked on an optional one.
//!
//! Setting up a new device is a sequence of steps, and some of them are not optional: the
//! device cannot be used safely until a screen lock is set, the person's account is
//! established, and the essential permissions are decided. Others — restoring a backup,
//! turning on extras — are conveniences a person may skip. Onboarding has to know the
//! difference, because two failures ruin it. Letting a person skip a required step drops
//! them into a device without a lock or an identity, which is unsafe and confusing. Blocking
//! them on an optional step they do not want makes setup a wall. So onboarding advances
//! through the steps in order, allows an optional step to be skipped and a required one only
//! to be completed, and reports setup done only when every required step is done. The result
//! is a setup a person can move through at their own pace that still guarantees the device
//! ends up in a usable, safe state.
//!
//! This module renders no screen. It decides the next step to show and whether onboarding is
//! complete, from the steps and what has been done, as pure functions.

const std = @import("std");

/// Whether a step must be completed or may be skipped.
pub const Requirement = enum { required, optional };

/// An onboarding step and its state.
pub const Step = struct {
    requirement: Requirement,
    /// Whether the person has completed it.
    completed: bool = false,
    /// Whether the person has skipped it. Only meaningful for optional steps.
    skipped: bool = false,

    /// Whether this step is resolved — done in a way that lets onboarding move past it. A
    /// required step resolves only by completion; an optional one resolves by completion or
    /// by being skipped.
    fn settled(step: Step) bool {
        if (step.completed) return true;
        return step.requirement == .optional and step.skipped;
    }
};

/// What onboarding does next.
pub const Next = union(enum) {
    /// Show the step at this index.
    show: usize,
    /// Every step is resolved and every required one completed; onboarding is done.
    complete,

    pub fn done(result: Next) bool {
        return result == .complete;
    }
};

/// Decides the next onboarding step to show, or that setup is complete.
///
/// The steps are walked in order; the first unresolved one is shown next. A required step is
/// unresolved until completed, so it cannot be walked past by skipping — the person stays on
/// it. An optional step is resolved once completed or skipped. When every step is resolved,
/// onboarding is complete, which — because required steps resolve only by completion —
/// guarantees every required step was actually done.
pub fn next(steps: []const Step) Next {
    for (steps, 0..) |step, index| {
        if (!step.settled()) return .{ .show = index };
    }
    return .complete;
}

/// Whether onboarding is complete: every required step completed and no step left unresolved.
pub fn isComplete(steps: []const Step) bool {
    return next(steps).done();
}

test "onboarding shows the first unresolved step" {
    const steps = [_]Step{
        .{ .requirement = .required, .completed = true },
        .{ .requirement = .required, .completed = false },
        .{ .requirement = .optional },
    };
    try std.testing.expectEqual(Next{ .show = 1 }, next(&steps));
}

test "a required step cannot be skipped past" {
    // A required step marked skipped but not completed stays unresolved.
    const steps = [_]Step{.{ .requirement = .required, .skipped = true, .completed = false }};
    try std.testing.expectEqual(Next{ .show = 0 }, next(&steps));
}

test "an optional step resolves when skipped" {
    const steps = [_]Step{
        .{ .requirement = .required, .completed = true },
        .{ .requirement = .optional, .skipped = true },
    };
    try std.testing.expect(isComplete(&steps));
}

test "onboarding completes only when every required step is done" {
    const done = [_]Step{
        .{ .requirement = .required, .completed = true },
        .{ .requirement = .optional, .skipped = true },
        .{ .requirement = .required, .completed = true },
    };
    try std.testing.expect(isComplete(&done));

    const not_done = [_]Step{
        .{ .requirement = .required, .completed = true },
        .{ .requirement = .required, .completed = false },
    };
    try std.testing.expect(!isComplete(&not_done));
}

test "empty onboarding is complete" {
    try std.testing.expect(isComplete(&.{}));
}

test "completion always implies every required step was completed, swept" {
    // The safety property: whenever onboarding reports complete, no required step was left
    // merely skipped.
    const configs = [_][]const Step{
        &.{ .{ .requirement = .required, .completed = true }, .{ .requirement = .optional, .skipped = true } },
        &.{.{ .requirement = .required, .skipped = true }},
        &.{.{ .requirement = .optional, .completed = true }},
    };
    for (configs) |steps| {
        if (isComplete(steps)) {
            for (steps) |step| {
                if (step.requirement == .required) try std.testing.expect(step.completed);
            }
        }
    }
}
