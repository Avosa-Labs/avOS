//! What the system knows about the battery, and what it must do as it drains.
//!
//! A battery reading is a hardware fact — a charge fraction, a voltage, a
//! temperature — and this module does not measure it. What it holds is the
//! policy that consumes a reading: which power state the device is in, when to
//! warn, when to shed work, when to save state before the lights go out. That
//! policy is testable across every charge level a real battery could never be
//! driven to on demand, and it is where a device either dies gracefully or
//! loses a person's work.
//!
//! The reading arrives through an interface, and the only implementation on a
//! host without a battery is a test source that reports exactly what a test
//! sets. Nothing here fabricates a plausible charge level, because a fabricated
//! one would let the power policy be tested against a curve no cell follows.

const std = @import("std");

/// Charge as a fraction of full, in hundredths of a percent.
///
/// Integer basis points rather than a float, so a level compares and serializes
/// identically everywhere and a threshold means the same thing twice. 10000 is
/// full, 0 is empty.
pub const ChargeBasisPoints = u16;

pub const full: ChargeBasisPoints = 10_000;

/// The power state the device is in, from a person's point of view.
///
/// Ordered by severity, so a comparison decides which of two states is worse.
/// Each state is where the system's behaviour changes, not merely a label on a
/// number.
pub const PowerState = enum(u8) {
    /// Plenty of charge. Nothing is held back.
    ample = 0,
    /// Enough to keep working, but worth a person knowing. Nothing is shed yet.
    adequate = 1,
    /// Low. Background and speculative work is shed to stretch what remains.
    low = 2,
    /// Critical. Only what a person is actively doing, plus what keeps the
    /// device reachable, continues.
    critical = 3,
    /// Empty enough that the device must save state and prepare to stop, while
    /// there is still charge to do it with.
    save_and_stop = 4,

    pub fn isWorseThan(state: PowerState, other: PowerState) bool {
        return @intFromEnum(state) > @intFromEnum(other);
    }

    /// Whether background and speculative work runs in this state.
    ///
    /// It stops at `low`, because the first thing a draining device should give
    /// up is work nobody is waiting on.
    pub fn permitsBackgroundWork(state: PowerState) bool {
        return @intFromEnum(state) < @intFromEnum(PowerState.low);
    }

    /// Whether the device must save state now, before it loses the charge to.
    ///
    /// Saving at the last possible moment is saving with no margin for the save
    /// itself to take time, so this triggers while there is deliberately some
    /// charge left.
    pub fn requiresStateSave(state: PowerState) bool {
        return state == .save_and_stop;
    }
};

/// The charge levels at which the power state changes.
///
/// Each is where a state begins, and the device stays in that state until the
/// charge rises back above the threshold by the hysteresis margin — so a device
/// hovering at a boundary does not flap between warning and not-warning many
/// times a minute.
pub const Thresholds = struct {
    adequate_below: ChargeBasisPoints,
    low_below: ChargeBasisPoints,
    critical_below: ChargeBasisPoints,
    save_below: ChargeBasisPoints,
    /// How far the charge must rise before a state relaxes. Never zero.
    hysteresis: ChargeBasisPoints,

    /// Whether the thresholds descend in the order the states require.
    ///
    /// Out-of-order thresholds would let a fuller battery pick a worse state,
    /// which is the one thing this must never do.
    pub fn areOrdered(thresholds: Thresholds) bool {
        return thresholds.adequate_below > thresholds.low_below and
            thresholds.low_below > thresholds.critical_below and
            thresholds.critical_below > thresholds.save_below and
            thresholds.hysteresis > 0;
    }

    /// A reference set for a handset: warn at 30%, shed at 15%, restrict at 5%,
    /// save at 2%.
    pub const reference: Thresholds = .{
        .adequate_below = 3_000,
        .low_below = 1_500,
        .critical_below = 500,
        .save_below = 200,
        .hysteresis = 300,
    };
};

/// A source of battery readings.
///
/// An interface, because a charge level is a hardware fact. On a board this is
/// the fuel gauge; in a test it is a value a test sets. There is no
/// implementation that reports a plausible level on a host without a battery.
pub const Source = struct {
    context_pointer: *anyopaque,
    readFn: *const fn (context_pointer: *anyopaque) ?ChargeBasisPoints,

    /// The current charge, or null if the gauge cannot be read.
    ///
    /// A gauge that cannot be read is treated as the worst case by the policy,
    /// not as full: a device that cannot tell how much charge it has must assume
    /// little rather than run until it dies without warning.
    pub fn read(source: Source) ?ChargeBasisPoints {
        return source.readFn(source.context_pointer);
    }
};

/// Decides the power state from a reading and the state already held.
///
/// The held state is an input because of hysteresis: a device relaxes to a
/// better state only once the charge has risen past the threshold by the margin,
/// so a reading near a boundary does not toggle the state.
pub fn stateFor(
    thresholds: Thresholds,
    current: PowerState,
    reading: ?ChargeBasisPoints,
) PowerState {
    // A gauge that cannot be read is assumed to be nearly empty. Assuming full
    // would let a device run to death with no warning.
    const charge = reading orelse return .save_and_stop;

    const escalated = worsen(thresholds, charge);
    if (escalated.isWorseThan(current)) return escalated;

    // Charging back up: stay in the current state until the charge has risen
    // above its threshold by the hysteresis margin.
    return relax(thresholds, current, charge);
}

fn worsen(thresholds: Thresholds, charge: ChargeBasisPoints) PowerState {
    if (charge < thresholds.save_below) return .save_and_stop;
    if (charge < thresholds.critical_below) return .critical;
    if (charge < thresholds.low_below) return .low;
    if (charge < thresholds.adequate_below) return .adequate;
    return .ample;
}

fn relax(thresholds: Thresholds, current: PowerState, charge: ChargeBasisPoints) PowerState {
    const margin = thresholds.hysteresis;
    return switch (current) {
        .ample => .ample,
        .adequate => if (charge >= thresholds.adequate_below + margin) .ample else .adequate,
        .low => if (charge >= thresholds.low_below + margin)
            relax(thresholds, .adequate, charge)
        else
            .low,
        .critical => if (charge >= thresholds.critical_below + margin)
            relax(thresholds, .low, charge)
        else
            .critical,
        .save_and_stop => if (charge >= thresholds.save_below + margin)
            relax(thresholds, .critical, charge)
        else
            .save_and_stop,
    };
}

/// A battery source that reports whatever a test sets.
///
/// Not a stand-in for a fuel gauge: it measures nothing and claims nothing. It
/// reports the value written to it so a test can drive the power policy across
/// levels a real cell could not be moved to on demand. Setting `readable` to
/// false reproduces a gauge that has failed.
pub const TestSource = struct {
    charge: ChargeBasisPoints = full,
    readable: bool = true,

    pub fn source(test_source: *TestSource) Source {
        return .{ .context_pointer = test_source, .readFn = readValue };
    }

    fn readValue(context_pointer: *anyopaque) ?ChargeBasisPoints {
        const test_source: *TestSource = @ptrCast(@alignCast(context_pointer));
        if (!test_source.readable) return null;
        return test_source.charge;
    }
};

test "the reference thresholds descend in order" {
    try std.testing.expect(Thresholds.reference.areOrdered());
}

test "unordered thresholds are rejected" {
    var broken = Thresholds.reference;
    broken.low_below = broken.adequate_below + 1;
    try std.testing.expect(!broken.areOrdered());

    var no_margin = Thresholds.reference;
    no_margin.hysteresis = 0;
    try std.testing.expect(!no_margin.areOrdered());
}

test "a draining battery worsens through every state" {
    const levels = [_]struct { charge: ChargeBasisPoints, expected: PowerState }{
        .{ .charge = 8_000, .expected = .ample },
        .{ .charge = 2_500, .expected = .adequate },
        .{ .charge = 1_000, .expected = .low },
        .{ .charge = 400, .expected = .critical },
        .{ .charge = 100, .expected = .save_and_stop },
    };
    var current: PowerState = .ample;
    for (levels) |step| {
        current = stateFor(Thresholds.reference, current, step.charge);
        try std.testing.expectEqual(step.expected, current);
    }
}

test "a fuller battery never selects a worse state" {
    // The property the whole mechanism exists for, swept across the range.
    var charge: ChargeBasisPoints = 0;
    var previous: PowerState = .save_and_stop;
    while (charge <= full) : (charge += 50) {
        const state = worsen(Thresholds.reference, charge);
        try std.testing.expect(!state.isWorseThan(previous));
        previous = state;
    }
}

test "a state holds until the charge rises past the hysteresis margin" {
    // Drop to low, then charge to just above the threshold: the state must not
    // relax yet, or a device on a marginal charger would flap.
    var current = stateFor(Thresholds.reference, .ample, 1_000);
    try std.testing.expectEqual(PowerState.low, current);

    current = stateFor(Thresholds.reference, current, 1_600);
    try std.testing.expectEqual(PowerState.low, current);

    // Above the threshold by more than the margin, it relaxes.
    current = stateFor(Thresholds.reference, current, 1_900);
    try std.testing.expectEqual(PowerState.adequate, current);
}

test "charging relaxes one state at a time" {
    // From critical, a charge above the critical threshold but still low must
    // become low, not jump to ample.
    const current = stateFor(Thresholds.reference, .critical, 1_000);
    try std.testing.expectEqual(PowerState.low, current);
}

test "a gauge that cannot be read is treated as nearly empty" {
    var source: TestSource = .{ .readable = false };
    const state = stateFor(Thresholds.reference, .ample, source.source().read());
    // Assuming full would let the device run to death with no warning.
    try std.testing.expectEqual(PowerState.save_and_stop, state);
}

test "background work stops at low and below" {
    try std.testing.expect(PowerState.ample.permitsBackgroundWork());
    try std.testing.expect(PowerState.adequate.permitsBackgroundWork());
    try std.testing.expect(!PowerState.low.permitsBackgroundWork());
    try std.testing.expect(!PowerState.critical.permitsBackgroundWork());
    try std.testing.expect(!PowerState.save_and_stop.permitsBackgroundWork());
}

test "state is saved while there is still charge to save it with" {
    // Only save_and_stop requires the save, and it triggers above empty so the
    // save itself has charge to complete.
    try std.testing.expect(PowerState.save_and_stop.requiresStateSave());
    try std.testing.expect(!PowerState.critical.requiresStateSave());
    try std.testing.expect(Thresholds.reference.save_below > 0);
}

test "a test source reports exactly what it is set to" {
    var source: TestSource = .{ .charge = 4_200 };
    try std.testing.expectEqual(@as(?ChargeBasisPoints, 4_200), source.source().read());
    source.charge = 800;
    try std.testing.expectEqual(@as(?ChargeBasisPoints, 800), source.source().read());
}

test "the power states are totally ordered by severity" {
    const states = [_]PowerState{ .ample, .adequate, .low, .critical, .save_and_stop };
    for (states, 0..) |better, i| {
        for (states[i + 1 ..]) |worse| {
            try std.testing.expect(worse.isWorseThan(better));
            try std.testing.expect(!better.isWorseThan(worse));
        }
    }
}
