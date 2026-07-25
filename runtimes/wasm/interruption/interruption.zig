//! Turning a task's cancellation and deadline into an epoch the WebAssembly engine
//! can interrupt on, so a guest that never returns to the host still stops.
//!
//! Fuel bounds work, but a guest can spin without burning host-visible fuel, or
//! simply take longer than the caller is willing to wait. The engine answers this
//! with an epoch counter: a store is given a deadline in epoch ticks, the host
//! advances the epoch on a timer, and when the deadline is reached the guest is
//! interrupted at the next instruction — a stop it cannot decline, unlike a
//! cooperative check it could ignore. This module owns the mapping from the reasons
//! a guest should stop — its task was cancelled, its deadline passed — to the epoch
//! deadline that enforces it, and the arithmetic that keeps that deadline from
//! wrapping into the past, where it would fire immediately.
//!
//! It computes deadlines and reports whether one has been reached; advancing the
//! epoch and interrupting the store is the engine's, driven by whatever timer the
//! host runs.

const std = @import("std");

/// The current epoch and how far ahead a guest may run before it is interrupted.
pub const Interrupter = struct {
    /// The epoch the host has advanced to. Monotonic; only ever increased.
    epoch: u64 = 0,
    /// Ticks a guest is granted past the current epoch by default. Far enough not
    /// to bind ordinary work, but bounded so a runaway guest still stops.
    default_grant: u64 = 1 << 20,

    pub fn init() Interrupter {
        return .{};
    }

    /// Advances the epoch by one tick, as the host's timer does. Saturating, so an
    /// epoch that has run for the life of the device cannot wrap back to zero and
    /// make a future deadline look already reached.
    pub fn tick(interrupter: *Interrupter) void {
        interrupter.epoch +|= 1;
    }

    /// The epoch deadline a guest granted `ticks` should carry: the current epoch
    /// plus the grant, clamped so it cannot wrap past the representable maximum into
    /// a value below the current epoch, which would interrupt the guest at once.
    pub fn deadlineAfter(interrupter: Interrupter, ticks: u64) u64 {
        return std.math.add(u64, interrupter.epoch, ticks) catch std.math.maxInt(u64);
    }

    /// The default deadline for a guest with no deadline of its own.
    pub fn defaultDeadline(interrupter: Interrupter) u64 {
        return interrupter.deadlineAfter(interrupter.default_grant);
    }

    /// Whether a guest carrying `deadline` should now be interrupted: the epoch has
    /// reached it.
    pub fn reached(interrupter: Interrupter, deadline: u64) bool {
        return interrupter.epoch >= deadline;
    }
};

/// Why a guest is to be interrupted, distinct from running out of fuel.
pub const Reason = enum {
    /// The guest's deadline in epoch ticks passed.
    deadline,
    /// The task the guest runs under was cancelled.
    cancelled,
};

/// A guest's stop condition: an epoch deadline and whether its task was cancelled.
/// Either one interrupts it; the reason distinguishes which for the caller.
pub const Condition = struct {
    deadline: u64,
    task_cancelled: bool = false,

    /// Why this guest should stop under the given interrupter, or null if it may
    /// keep running. Cancellation outranks the deadline: a cancelled task stops now
    /// whether or not its deadline has passed.
    pub fn stop(condition: Condition, interrupter: Interrupter) ?Reason {
        if (condition.task_cancelled) return .cancelled;
        if (interrupter.reached(condition.deadline)) return .deadline;
        return null;
    }
};

// --- Tests ---

const testing = std.testing;

test "a guest is interrupted once the epoch reaches its deadline" {
    var interrupter = Interrupter.init();
    const deadline = interrupter.deadlineAfter(3);
    const condition: Condition = .{ .deadline = deadline };
    try testing.expect(condition.stop(interrupter) == null);
    interrupter.tick();
    interrupter.tick();
    try testing.expect(condition.stop(interrupter) == null); // epoch 2, deadline 3
    interrupter.tick();
    try testing.expectEqual(Reason.deadline, condition.stop(interrupter).?); // epoch 3
}

test "a cancelled task stops now, ahead of its deadline" {
    const interrupter = Interrupter.init();
    const condition: Condition = .{ .deadline = interrupter.deadlineAfter(1000), .task_cancelled = true };
    try testing.expectEqual(Reason.cancelled, condition.stop(interrupter).?);
}

test "a deadline cannot wrap into the past" {
    var interrupter = Interrupter.init();
    interrupter.epoch = std.math.maxInt(u64) - 2;
    // A large grant clamps to the maximum rather than wrapping below the epoch.
    const deadline = interrupter.deadlineAfter(1000);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), deadline);
    try testing.expect(!interrupter.reached(deadline));
}

test "the epoch saturates rather than wrapping to zero" {
    var interrupter = Interrupter.init();
    interrupter.epoch = std.math.maxInt(u64);
    interrupter.tick();
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), interrupter.epoch);
}

test "a guest with no deadline of its own gets a bounded default" {
    const interrupter = Interrupter.init();
    const deadline = interrupter.defaultDeadline();
    try testing.expect(deadline > interrupter.epoch);
    try testing.expect(!interrupter.reached(deadline));
}
