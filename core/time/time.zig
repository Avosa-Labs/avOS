//! Time as the control plane sees it.
//!
//! Nothing in the domain reads a system clock directly. Every expiry,
//! deadline, and audit timestamp resolves through a `Clock`, so a scenario can
//! run with a clock the test advances by hand and produce identical results
//! every time.
//!
//! Clock movement is an adversary, not a convenience: the wall clock can jump
//! backwards, so anything that must only move forward uses a monotonic reading
//! instead.

const std = @import("std");

/// Nanoseconds since the Unix epoch, ignoring leap seconds.
///
/// Signed so that arithmetic near the epoch and backwards clock movement are
/// representable rather than wrapping.
pub const Timestamp = struct {
    nanoseconds: i64,

    pub const epoch: Timestamp = .{ .nanoseconds = 0 };

    pub fn fromSeconds(count: i64) Timestamp {
        return .{ .nanoseconds = count * std.time.ns_per_s };
    }

    pub fn seconds(timestamp: Timestamp) i64 {
        return @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    }

    /// Saturating addition. A deadline computed near the representable limit
    /// clamps rather than wrapping into the past.
    pub fn plus(timestamp: Timestamp, duration: Duration) Timestamp {
        return .{ .nanoseconds = timestamp.nanoseconds +| duration.nanoseconds };
    }

    pub fn order(timestamp: Timestamp, other: Timestamp) std.math.Order {
        return std.math.order(timestamp.nanoseconds, other.nanoseconds);
    }

    pub fn isAfter(timestamp: Timestamp, other: Timestamp) bool {
        return timestamp.order(other) == .gt;
    }

    /// Elapsed time from `earlier` to `timestamp`. Negative when the clock
    /// moved backwards, which callers must handle rather than assume away.
    pub fn since(timestamp: Timestamp, earlier: Timestamp) Duration {
        return .{ .nanoseconds = timestamp.nanoseconds -| earlier.nanoseconds };
    }

    pub fn format(timestamp: Timestamp, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const total = timestamp.seconds();
        const fractional = @mod(timestamp.nanoseconds, std.time.ns_per_s);
        if (total < 0) {
            try writer.print("-{d}.{d:0>9}", .{ -total, fractional });
            return;
        }
        try writer.print("{d}.{d:0>9}", .{ total, fractional });
    }
};

pub const Duration = struct {
    nanoseconds: i64,

    pub const zero: Duration = .{ .nanoseconds = 0 };

    pub fn fromMilliseconds(count: i64) Duration {
        return .{ .nanoseconds = count * std.time.ns_per_ms };
    }

    pub fn fromSeconds(count: i64) Duration {
        return .{ .nanoseconds = count * std.time.ns_per_s };
    }

    pub fn milliseconds(duration: Duration) i64 {
        return @divFloor(duration.nanoseconds, std.time.ns_per_ms);
    }

    pub fn isPositive(duration: Duration) bool {
        return duration.nanoseconds > 0;
    }
};

/// Reads time without revealing which implementation supplies it.
///
/// `wall` may jump in either direction; `monotonic` never decreases. Expiry
/// comparisons use `wall` because a capability's validity is stated in real
/// time; elapsed-time measurements use `monotonic`.
pub const Clock = struct {
    context: *anyopaque,
    wallFn: *const fn (context: *anyopaque) Timestamp,
    monotonicFn: *const fn (context: *anyopaque) Timestamp,

    pub fn wall(clock: Clock) Timestamp {
        return clock.wallFn(clock.context);
    }

    pub fn monotonic(clock: Clock) Timestamp {
        return clock.monotonicFn(clock.context);
    }
};

/// A clock the caller advances explicitly.
///
/// This is the only clock a scenario uses. Because nothing sleeps and nothing
/// samples the host, a run takes no wall-clock time and produces the same
/// timestamps on every machine.
pub const ManualClock = struct {
    wall_time: Timestamp,
    monotonic_time: Timestamp,

    pub fn init(start: Timestamp) ManualClock {
        return .{ .wall_time = start, .monotonic_time = .epoch };
    }

    pub fn clock(manual: *ManualClock) Clock {
        return .{
            .context = manual,
            .wallFn = readWall,
            .monotonicFn = readMonotonic,
        };
    }

    /// Advances both readings. This is the ordinary way time passes.
    pub fn advance(manual: *ManualClock, duration: Duration) void {
        manual.wall_time = manual.wall_time.plus(duration);
        manual.monotonic_time = manual.monotonic_time.plus(duration);
    }

    /// Moves the wall clock without moving the monotonic clock, reproducing a
    /// time-synchronization correction or an administrator changing the clock.
    /// Used to prove that expiry and elapsed-time logic survive it.
    pub fn skewWall(manual: *ManualClock, duration: Duration) void {
        manual.wall_time = manual.wall_time.plus(duration);
    }

    fn readWall(context: *anyopaque) Timestamp {
        const manual: *ManualClock = @ptrCast(@alignCast(context));
        return manual.wall_time;
    }

    fn readMonotonic(context: *anyopaque) Timestamp {
        const manual: *ManualClock = @ptrCast(@alignCast(context));
        return manual.monotonic_time;
    }
};

test "a manual clock only moves when advanced" {
    var manual: ManualClock = .init(.fromSeconds(1_000));
    const clock = manual.clock();

    try std.testing.expectEqual(@as(i64, 1_000), clock.wall().seconds());
    try std.testing.expectEqual(@as(i64, 1_000), clock.wall().seconds());

    manual.advance(.fromSeconds(30));
    try std.testing.expectEqual(@as(i64, 1_030), clock.wall().seconds());
}

test "the monotonic reading does not follow a backwards wall correction" {
    var manual: ManualClock = .init(.fromSeconds(1_000));
    const clock = manual.clock();

    manual.advance(.fromSeconds(10));
    const monotonic_before = clock.monotonic();

    manual.skewWall(.fromSeconds(-3_600));

    try std.testing.expectEqual(monotonic_before.nanoseconds, clock.monotonic().nanoseconds);
    try std.testing.expect(clock.wall().seconds() < 1_000);
}

test "elapsed time is negative when the wall clock moves backwards" {
    // Callers must handle this rather than assume monotonicity of `wall`.
    const later: Timestamp = .fromSeconds(100);
    const earlier: Timestamp = .fromSeconds(500);
    try std.testing.expect(later.since(earlier).nanoseconds < 0);
}

test "deadline arithmetic saturates instead of wrapping into the past" {
    const near_limit: Timestamp = .{ .nanoseconds = std.math.maxInt(i64) - 5 };
    const far: Duration = .{ .nanoseconds = std.math.maxInt(i64) };
    const deadline = near_limit.plus(far);
    try std.testing.expect(!deadline.isAfter(.{ .nanoseconds = std.math.maxInt(i64) }));
    try std.testing.expect(deadline.isAfter(near_limit));
}

test "ordering and comparison agree" {
    const earlier: Timestamp = .fromSeconds(1);
    const later: Timestamp = .fromSeconds(2);
    try std.testing.expectEqual(std.math.Order.lt, earlier.order(later));
    try std.testing.expectEqual(std.math.Order.eq, earlier.order(earlier));
    try std.testing.expect(later.isAfter(earlier));
    try std.testing.expect(!earlier.isAfter(earlier));
}

test "two runs of the same scenario produce identical timestamps" {
    var first: ManualClock = .init(.fromSeconds(1_700_000_000));
    var second: ManualClock = .init(.fromSeconds(1_700_000_000));
    const steps = [_]i64{ 5, 250, 1, 4_000 };
    for (steps) |step| {
        first.advance(.fromMilliseconds(step));
        second.advance(.fromMilliseconds(step));
        try std.testing.expectEqual(
            first.clock().wall().nanoseconds,
            second.clock().wall().nanoseconds,
        );
    }
}
