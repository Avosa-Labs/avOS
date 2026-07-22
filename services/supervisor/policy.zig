//! Restart policy for supervised services.
//!
//! Deciding whether to restart a service is separated from spawning one, so the
//! decision can be exercised for every combination of exit condition and
//! history without starting a process. A supervisor that only fails under real
//! crashes is a supervisor whose crash-loop handling has never been tested.
//!
//! Restarts are bounded. A service that fails immediately and repeatedly is
//! quarantined rather than restarted forever: an unbounded restart loop
//! consumes the host it is meant to keep available, and it hides the fault
//! instead of surfacing it.

const std = @import("std");
const core = @import("core");

const time = core.time;

/// How a supervised process ended.
pub const Exit = union(enum) {
    /// Exited with a status. Zero means it completed its work.
    exited: u8,
    /// Killed by a signal. A fault, or a stop the supervisor requested.
    signalled: u32,
    /// Ended in a way the host could not classify.
    unknown,

    pub fn isClean(exit: Exit) bool {
        return switch (exit) {
            .exited => |status| status == 0,
            .signalled, .unknown => false,
        };
    }
};

pub const RestartPolicy = enum {
    /// Never restarted. For work that runs once.
    never,
    /// Restarted only when it ended badly.
    on_failure,
    /// Restarted whenever it ends, including a clean exit. For a service that
    /// is supposed to stay up.
    always,
};

pub const Decision = enum {
    /// Start it again after the computed delay.
    restart,
    /// Leave it stopped; this is its expected end.
    leave_stopped,
    /// Stop restarting it: it is failing faster than it can be useful.
    quarantine,
};

/// Bounds how often a service may be restarted.
///
/// The window matters as much as the count. A service that has run for hours
/// and then crashes is not crash-looping, so its failure history is forgotten
/// once it has stayed up long enough to be considered healthy.
pub const Limits = struct {
    /// Restarts permitted before the service is quarantined.
    max_restarts: u32 = 5,
    /// How long a service must stay up before its failure history is cleared.
    healthy_after: time.Duration = .{ .nanoseconds = 30 * std.time.ns_per_s },
    /// Delay before the first restart.
    initial_backoff: time.Duration = .{ .nanoseconds = 100 * std.time.ns_per_ms },
    /// Ceiling on the delay, so backoff does not grow without bound.
    max_backoff: time.Duration = .{ .nanoseconds = 30 * std.time.ns_per_s },
};

/// What the supervisor remembers about one service.
pub const History = struct {
    /// Consecutive failures since the service was last considered healthy.
    consecutive_failures: u32 = 0,
    /// Restarts performed since the service was last considered healthy.
    restarts: u32 = 0,
    /// When the current run started.
    started_at: time.Timestamp = .epoch,

    /// Clears the failure history after a run long enough to count as healthy.
    pub fn observeHealthy(history: *History) void {
        history.consecutive_failures = 0;
        history.restarts = 0;
    }
};

/// Decides what to do when a supervised service ends.
///
/// A run that lasted long enough to be healthy resets the history first, so a
/// long-lived service that crashes once is restarted promptly rather than being
/// judged against failures from hours earlier.
pub fn decide(
    policy: RestartPolicy,
    limits: Limits,
    history: *History,
    exit: Exit,
    ran_for: time.Duration,
) Decision {
    if (ran_for.nanoseconds >= limits.healthy_after.nanoseconds) {
        history.observeHealthy();
    }

    if (!exit.isClean()) history.consecutive_failures += 1;

    return switch (policy) {
        .never => .leave_stopped,
        .on_failure => if (exit.isClean())
            .leave_stopped
        else if (history.restarts >= limits.max_restarts)
            .quarantine
        else
            .restart,
        .always => if (history.restarts >= limits.max_restarts)
            .quarantine
        else
            .restart,
    };
}

/// Delay before the next restart.
///
/// Doubles per consecutive restart and saturates at the ceiling. Saturating
/// arithmetic matters: a shift past the width of the type would wrap to a short
/// delay and turn backoff into a tight loop.
pub fn backoff(limits: Limits, restarts: u32) time.Duration {
    if (restarts == 0) return limits.initial_backoff;

    const shift: u6 = @intCast(@min(restarts, 32));
    const multiplier: i64 = if (shift >= 62) std.math.maxInt(i64) else @as(i64, 1) << @intCast(@min(shift, 62));

    const scaled = std.math.mul(i64, limits.initial_backoff.nanoseconds, multiplier) catch
        return limits.max_backoff;

    return .{ .nanoseconds = @min(scaled, limits.max_backoff.nanoseconds) };
}

test "a clean exit under on-failure leaves the service stopped" {
    var history: History = .{};
    const decision = decide(.on_failure, .{}, &history, .{ .exited = 0 }, .fromSeconds(1));
    try std.testing.expectEqual(Decision.leave_stopped, decision);
}

test "a failing exit under on-failure restarts the service" {
    var history: History = .{};
    try std.testing.expectEqual(
        Decision.restart,
        decide(.on_failure, .{}, &history, .{ .exited = 3 }, .fromSeconds(1)),
    );
    try std.testing.expectEqual(@as(u32, 1), history.consecutive_failures);
}

test "a signalled service is a failure, not a clean exit" {
    // A service killed by a fault must never be mistaken for one that finished.
    var history: History = .{};
    try std.testing.expectEqual(
        Decision.restart,
        decide(.on_failure, .{}, &history, .{ .signalled = 11 }, .fromSeconds(1)),
    );
    try std.testing.expect(!(Exit{ .signalled = 11 }).isClean());
    try std.testing.expect(!(Exit{ .unknown = {} }).isClean());
    try std.testing.expect((Exit{ .exited = 0 }).isClean());
    try std.testing.expect(!(Exit{ .exited = 1 }).isClean());
}

test "a service that never restarts stays stopped however it ended" {
    var history: History = .{};
    const exits = [_]Exit{ .{ .exited = 0 }, .{ .exited = 9 }, .{ .signalled = 11 }, .unknown };
    for (exits) |exit| {
        try std.testing.expectEqual(
            Decision.leave_stopped,
            decide(.never, .{}, &history, exit, .fromSeconds(1)),
        );
    }
}

test "an always-restart service is restarted even after a clean exit" {
    var history: History = .{};
    try std.testing.expectEqual(
        Decision.restart,
        decide(.always, .{}, &history, .{ .exited = 0 }, .fromSeconds(1)),
    );
}

test "a service failing repeatedly is quarantined rather than restarted forever" {
    const limits: Limits = .{ .max_restarts = 3 };
    var history: History = .{};

    // Each failure is followed by a restart the supervisor records.
    for (0..3) |_| {
        try std.testing.expectEqual(
            Decision.restart,
            decide(.on_failure, limits, &history, .{ .exited = 1 }, .fromMilliseconds(5)),
        );
        history.restarts += 1;
    }

    try std.testing.expectEqual(
        Decision.quarantine,
        decide(.on_failure, limits, &history, .{ .exited = 1 }, .fromMilliseconds(5)),
    );
}

test "a service that stayed up long enough is not judged by old failures" {
    const limits: Limits = .{ .max_restarts = 2, .healthy_after = .fromSeconds(30) };
    var history: History = .{ .consecutive_failures = 9, .restarts = 9 };

    // A long run clears the history, so this crash is treated as the first.
    const decision = decide(.on_failure, limits, &history, .{ .exited = 1 }, .fromSeconds(60));

    try std.testing.expectEqual(Decision.restart, decision);
    try std.testing.expectEqual(@as(u32, 0), history.restarts);
    try std.testing.expectEqual(@as(u32, 1), history.consecutive_failures);
}

test "a short run does not clear the failure history" {
    const limits: Limits = .{ .max_restarts = 2, .healthy_after = .fromSeconds(30) };
    var history: History = .{ .restarts = 2 };

    try std.testing.expectEqual(
        Decision.quarantine,
        decide(.on_failure, limits, &history, .{ .exited = 1 }, .fromMilliseconds(10)),
    );
}

test "backoff grows and then saturates at the ceiling" {
    const limits: Limits = .{
        .initial_backoff = .fromMilliseconds(100),
        .max_backoff = .fromSeconds(30),
    };

    try std.testing.expectEqual(@as(i64, 100), backoff(limits, 0).milliseconds());
    try std.testing.expectEqual(@as(i64, 200), backoff(limits, 1).milliseconds());
    try std.testing.expectEqual(@as(i64, 400), backoff(limits, 2).milliseconds());
    try std.testing.expectEqual(@as(i64, 800), backoff(limits, 3).milliseconds());

    // It must never exceed the ceiling, however many restarts have happened.
    for (0..64) |restarts| {
        const delay = backoff(limits, @intCast(restarts));
        try std.testing.expect(delay.nanoseconds <= limits.max_backoff.nanoseconds);
        try std.testing.expect(delay.nanoseconds > 0);
    }
}

test "backoff never wraps into a tight loop at extreme restart counts" {
    // A shift wider than the type would wrap to a small delay, turning backoff
    // into the busy restart loop it exists to prevent.
    const limits: Limits = .{
        .initial_backoff = .fromMilliseconds(100),
        .max_backoff = .fromSeconds(30),
    };
    const extreme = [_]u32{ 62, 63, 64, 1_000, std.math.maxInt(u32) };
    for (extreme) |restarts| {
        const delay = backoff(limits, restarts);
        try std.testing.expectEqual(limits.max_backoff.nanoseconds, delay.nanoseconds);
    }
}

test "every policy and exit combination yields a defined decision" {
    // The decision table must be total: an unhandled combination would leave a
    // service in an unknown state after it ended.
    const exits = [_]Exit{ .{ .exited = 0 }, .{ .exited = 1 }, .{ .signalled = 9 }, .unknown };
    for (std.enums.values(RestartPolicy)) |policy| {
        for (exits) |exit| {
            for ([_]i64{ 0, 1, 100_000 }) |milliseconds| {
                var history: History = .{};
                _ = decide(policy, .{}, &history, exit, .fromMilliseconds(milliseconds));
            }
        }
    }
}
