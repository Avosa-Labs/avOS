//! Charges each service call against a bounded resource pool and releases it when
//! the call ends, so no caller can make a service commit more than its budget.
//!
//! Admission (`resource/admission.zig`) decides whether a reservation *fits* a pool,
//! but it decides over a pool state someone else holds; it commits nothing. A
//! running service needs the state as well as the decision: the units a call in
//! flight is holding, so the next call is admitted against what is actually left,
//! and released when the call returns so a burst of work does not permanently
//! consume the budget. This is that state. Every call reserves its declared cost on
//! entry and returns it on exit; a call whose cost will not fit is refused at the
//! boundary as budget-exhausted, before the handler runs, rather than admitted and
//! then failing when the memory is touched.
//!
//! System-priority callers may draw into the reserve the pool holds back, so the
//! components that keep the device recoverable are not starved by an application
//! flood — the reserve rule the admission module defines, now enforced against live
//! commitments. A caller that never releases what it reserved would leak the budget;
//! the meter counts live reservations so that leak is observable rather than silent.

const std = @import("std");
const admission = @import("../resource/admission.zig");

pub const Priority = admission.Priority;
pub const Refusal = admission.Refusal;

/// A live reservation, returned by a successful charge and required to release it.
/// Holding the units it reserved is what lets release return exactly that much,
/// rather than trusting a caller to name the right amount twice.
pub const Reservation = struct {
    units: u64,
    priority: Priority,
};

/// The result of trying to charge a call against the pool.
pub const Charge = union(enum) {
    /// The units were committed; hold this to release them.
    admitted: Reservation,
    /// The pool could not fit the call at the caller's priority.
    refused: Refusal,

    pub fn ok(charge: Charge) bool {
        return charge == .admitted;
    }
};

/// A resource pool with live commitments, charged per call and released on return.
///
/// Not threadsafe. One meter belongs to one service's receive path; the commitment
/// count is on the path of every call and sharing it across threads would need a
/// lock there.
pub const Meter = struct {
    pool: admission.Pool,
    /// Calls charged but not yet released. A non-zero count at a quiescent service
    /// means budget was reserved and never returned — a leak the meter surfaces
    /// rather than hides.
    in_flight: u64 = 0,
    /// The high-water mark of committed units, so a service can size its pool from
    /// what it actually reached rather than from a guess.
    peak_committed: u64 = 0,

    pub fn init(capacity: u64, reserved_for_system: u64) Meter {
        return .{ .pool = .{
            .capacity = capacity,
            .reserved_for_system = reserved_for_system,
            .committed = 0,
        } };
    }

    /// Reserves `units` for a call of the given priority, committing them if they
    /// fit. A refusal commits nothing, so a call that cannot be afforded never runs.
    pub fn charge(meter: *Meter, priority: Priority, units: u64) Charge {
        switch (admission.decide(meter.pool, priority, units)) {
            .grant => {
                meter.pool.committed += units;
                meter.in_flight += 1;
                if (meter.pool.committed > meter.peak_committed) {
                    meter.peak_committed = meter.pool.committed;
                }
                return .{ .admitted = .{ .units = units, .priority = priority } };
            },
            .refuse => |refusal| return .{ .refused = refusal },
        }
    }

    /// Returns a reservation's units to the pool. Takes the reservation the charge
    /// handed out, so exactly what was committed is what is released — a call cannot
    /// release more than it reserved, or another's reservation by naming a number.
    pub fn release(meter: *Meter, reservation: Reservation) void {
        // Guard against underflow: releasing more than is committed would corrupt
        // the pool into thinking it has room it does not.
        meter.pool.committed -= @min(reservation.units, meter.pool.committed);
        if (meter.in_flight > 0) meter.in_flight -= 1;
    }

    /// The units still committed, i.e. held by calls in flight.
    pub fn committed(meter: Meter) u64 {
        return meter.pool.committed;
    }

    /// Whether every reservation has been released — the invariant a quiescent
    /// service must hold.
    pub fn isBalanced(meter: Meter) bool {
        return meter.in_flight == 0 and meter.pool.committed == 0;
    }
};

// --- Tests ---

test "a call within budget is charged and released back to balance" {
    var meter = Meter.init(1000, 200);
    const charge = meter.charge(.ordinary, 300);
    try std.testing.expect(charge.ok());
    try std.testing.expectEqual(@as(u64, 300), meter.committed());
    try std.testing.expectEqual(@as(u64, 1), meter.in_flight);

    meter.release(charge.admitted);
    try std.testing.expect(meter.isBalanced());
}

test "a call that does not fit the general portion is refused as exhausted" {
    var meter = Meter.init(1000, 200); // general limit 800
    // Commit 700 with one call, then a 200-unit ordinary call would reach 900.
    const first = meter.charge(.ordinary, 700);
    try std.testing.expect(first.ok());
    const second = meter.charge(.ordinary, 200);
    try std.testing.expect(!second.ok());
    try std.testing.expectEqual(Refusal.general_exhausted, second.refused);
    // The refused call committed nothing.
    try std.testing.expectEqual(@as(u64, 700), meter.committed());
    meter.release(first.admitted);
}

test "a system call may draw into the reserve an ordinary call cannot" {
    var meter = Meter.init(1000, 200);
    const fill = meter.charge(.ordinary, 800); // general limit reached
    try std.testing.expect(fill.ok());
    // Ordinary is refused, system draws into the reserve.
    try std.testing.expect(!meter.charge(.ordinary, 100).ok());
    const system = meter.charge(.system, 100);
    try std.testing.expect(system.ok());
    meter.release(fill.admitted);
    meter.release(system.admitted);
    try std.testing.expect(meter.isBalanced());
}

test "releasing more than committed cannot underflow the pool" {
    var meter = Meter.init(1000, 0);
    const charge = meter.charge(.ordinary, 100);
    try std.testing.expect(charge.ok());
    // Release a fabricated over-large reservation: the pool floors at zero.
    meter.release(.{ .units = 100_000, .priority = .ordinary });
    try std.testing.expectEqual(@as(u64, 0), meter.committed());
}

test "the peak commitment records the high-water mark across calls" {
    var meter = Meter.init(1000, 0);
    const a = meter.charge(.ordinary, 400);
    const b = meter.charge(.ordinary, 300); // peak 700
    meter.release(b.admitted);
    const c = meter.charge(.ordinary, 100); // committed 500, below peak
    try std.testing.expectEqual(@as(u64, 700), meter.peak_committed);
    meter.release(a.admitted);
    meter.release(c.admitted);
}

test "a leaked reservation leaves the meter unbalanced, swept" {
    // The leak-visibility property: charging without releasing keeps in_flight and
    // committed non-zero, so a service can assert balance and catch the leak.
    var meter = Meter.init(10_000, 0);
    var reservations: [8]Reservation = undefined;
    for (&reservations, 0..) |*reservation, index| {
        const charge = meter.charge(.ordinary, 100);
        try std.testing.expect(charge.ok());
        reservation.* = charge.admitted;
        try std.testing.expectEqual(@as(u64, index + 1), meter.in_flight);
    }
    try std.testing.expect(!meter.isBalanced());
    // Releasing all of them restores balance.
    for (reservations) |reservation| meter.release(reservation);
    try std.testing.expect(meter.isBalanced());
}
