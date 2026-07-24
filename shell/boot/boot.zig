//! Deciding what the boot surface shows as the device starts, so a person watching a
//! device come up sees honest, forward-only progress rather than a frozen or lying screen.
//!
//! Boot is the first thing a person sees, and the boot surface has one job: reflect where
//! the device actually is in starting up, truthfully. That truth has a shape. Startup moves
//! through ordered stages — verifying the system, starting services, preparing the session —
//! and it moves through them forward: progress never goes backward, because a boot screen
//! that jumps from a later stage to an earlier one tells the person something is wrong when
//! it may not be, and erodes the trust the boot screen exists to build. If a stage fails,
//! the surface does not sit forever pretending to progress; it shows the failure and the
//! path to recovery, because a spinner that never resolves is worse than an honest error.
//! So the boot surface reflects the current stage, shows monotonic progress toward ready,
//! and surfaces a failure as a failure — a small contract that makes the most anxious moment
//! of using a device, waiting for it to start, feel trustworthy.
//!
//! This module boots nothing. It decides what the boot surface displays for a given stage,
//! and validates that stage progress only moves forward, as pure functions.

const std = @import("std");

/// The ordered stages of startup, from first to ready.
pub const Stage = enum(u8) {
    /// Verifying the system image and integrity.
    verifying = 0,
    /// Starting the control-plane services.
    starting_services = 1,
    /// Preparing the person's session.
    preparing_session = 2,
    /// Ready: the shell is up.
    ready = 3,

    fn order(stage: Stage) u8 {
        return @intFromEnum(stage);
    }
};

/// What the boot surface should show.
pub const Display = union(enum) {
    /// Show progress at this stage, with a fraction 0..100 toward ready.
    progress: struct { stage: Stage, percent: u8 },
    /// Startup finished; hand off to the shell.
    ready,
    /// A stage failed; show the failure and the recovery path.
    failed: Stage,
};

/// The completion percentage a stage represents on the way to ready.
fn stagePercent(stage: Stage) u8 {
    return switch (stage) {
        .verifying => 25,
        .starting_services => 50,
        .preparing_session => 75,
        .ready => 100,
    };
}

/// Decides what the boot surface displays for the current stage.
///
/// A failed stage shows the failure, so a stuck boot becomes a visible error with a way out
/// rather than an endless spinner. The ready stage hands off to the shell. Any other stage
/// shows progress at that stage's completion percentage — a monotonic fraction toward ready,
/// so the bar only ever moves forward.
pub fn display(stage: Stage, failed: bool) Display {
    if (failed) return .{ .failed = stage };
    if (stage == .ready) return .ready;
    return .{ .progress = .{ .stage = stage, .percent = stagePercent(stage) } };
}

/// Whether a stage transition is valid: progress only moves forward, never back to an
/// earlier stage.
pub fn validTransition(from: Stage, to: Stage) bool {
    return to.order() >= from.order();
}

test "an early stage shows progress" {
    switch (display(.verifying, false)) {
        .progress => |p| {
            try std.testing.expectEqual(Stage.verifying, p.stage);
            try std.testing.expectEqual(@as(u8, 25), p.percent);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "the ready stage hands off" {
    try std.testing.expectEqual(Display.ready, display(.ready, false));
}

test "a failed stage shows the failure" {
    try std.testing.expectEqual(Display{ .failed = .starting_services }, display(.starting_services, true));
}

test "progress increases with stage" {
    try std.testing.expect(stagePercent(.verifying) < stagePercent(.starting_services));
    try std.testing.expect(stagePercent(.starting_services) < stagePercent(.preparing_session));
    try std.testing.expect(stagePercent(.preparing_session) < stagePercent(.ready));
}

test "forward transitions are valid, backward ones are not" {
    try std.testing.expect(validTransition(.verifying, .starting_services));
    try std.testing.expect(validTransition(.verifying, .verifying)); // staying is fine
    try std.testing.expect(!validTransition(.preparing_session, .verifying));
}

test "boot progress is monotonic, swept" {
    // The forward-only property: a transition is valid exactly when it does not regress.
    const stages = [_]Stage{ .verifying, .starting_services, .preparing_session, .ready };
    for (stages) |from| {
        for (stages) |to| {
            try std.testing.expectEqual(to.order() >= from.order(), validTransition(from, to));
        }
    }
}

test "a failure is always shown as a failure, swept" {
    // The honest-error property: whatever the stage, a failed boot shows the failure, never
    // a progress bar.
    const stages = [_]Stage{ .verifying, .starting_services, .preparing_session, .ready };
    for (stages) |stage| {
        try std.testing.expectEqual(Display{ .failed = stage }, display(stage, true));
    }
}
