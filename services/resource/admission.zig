//! Deciding whether a resource reservation may be granted, keeping a reserve for the
//! system so a device never starves the very services that keep it recoverable.
//!
//! Compute, memory, and bandwidth are finite, and handing them out first-come
//! first-served is how a device wedges itself: an application grabs the last of the
//! memory, and now the update service that would fix the application cannot run, and
//! the diagnostics that would explain the wedge cannot either. So a reservation is
//! admitted against a pool that holds a reserve back for system work. Ordinary
//! requesters draw only from the general portion; once that is spent they are
//! refused, while system requesters may draw into the reserve, so the components that
//! keep the device alive and recoverable always have headroom that an application
//! flood cannot consume. A grant that fits is admitted and its amount committed; one
//! that does not is refused at request time rather than granted and then failing when
//! the resource is actually touched.
//!
//! This module allocates nothing. It decides whether a reservation fits the pool for
//! the requester's priority, as a pure function over the pool state and the request.

const std = @import("std");

/// How important a requester is to keeping the device working, which decides whether
/// it may draw on the reserve.
pub const Priority = enum {
    /// An ordinary application or agent. Draws only from the general portion.
    ordinary,
    /// A system component the device needs to stay recoverable. May draw into the
    /// reserve.
    system,

    fn mayUseReserve(priority: Priority) bool {
        return priority == .system;
    }
};

/// A resource pool with a reserve held back for system work.
pub const Pool = struct {
    /// The total resource units the pool holds.
    capacity: u64,
    /// Units of the capacity reserved for system priority. Must not exceed capacity.
    reserved_for_system: u64,
    /// Units currently committed.
    committed: u64,

    /// The ceiling ordinary requesters may reach: everything but the reserve.
    fn generalLimit(pool: Pool) u64 {
        return pool.capacity - pool.reserved_for_system;
    }
};

/// Why a reservation was refused.
pub const Refusal = enum {
    /// The general portion is exhausted and the requester is not entitled to the
    /// reserve.
    general_exhausted,
    /// Even the reserve cannot fit the request: the pool is at its hard capacity.
    at_capacity,
};

/// The admission decision.
pub const Decision = union(enum) {
    grant,
    refuse: Refusal,

    pub fn granted(decision: Decision) bool {
        return decision == .grant;
    }
};

/// Decides whether a reservation of `units` is granted to a requester of a given
/// priority.
///
/// The ceiling the request is checked against depends on priority: an ordinary
/// requester may reach only the general limit, while a system requester may reach the
/// full capacity, drawing into the reserve. A request that fits under its ceiling is
/// granted; one that does not is refused — as exhausting the general portion for an
/// ordinary requester, or as hitting hard capacity for a system one. Wide arithmetic
/// keeps a large request from wrapping the committed total under the ceiling.
pub fn decide(pool: Pool, priority: Priority, units: u64) Decision {
    const ceiling = if (priority.mayUseReserve()) pool.capacity else pool.generalLimit();
    const after = @as(u128, pool.committed) + units;
    if (after <= ceiling) return .grant;
    // Did not fit. Distinguish the general-exhaustion case from hard capacity.
    if (!priority.mayUseReserve() and @as(u128, pool.committed) + units <= pool.capacity) {
        return .{ .refuse = .general_exhausted };
    }
    return .{ .refuse = .at_capacity };
}

fn poolOf(capacity: u64, reserved: u64, committed: u64) Pool {
    return .{ .capacity = capacity, .reserved_for_system = reserved, .committed = committed };
}

test "a request within the general limit is granted to an ordinary requester" {
    const pool = poolOf(1000, 200, 100);
    try std.testing.expect(decide(pool, .ordinary, 500).granted());
}

test "an ordinary requester is refused once the general portion is exhausted" {
    // General limit is 800; committed 750; a 100-unit request would reach 850, into
    // the reserve.
    const pool = poolOf(1000, 200, 750);
    try std.testing.expectEqual(Decision{ .refuse = .general_exhausted }, decide(pool, .ordinary, 100));
}

test "a system requester may draw into the reserve" {
    const pool = poolOf(1000, 200, 750);
    try std.testing.expect(decide(pool, .system, 100).granted());
}

test "even a system requester is refused past hard capacity" {
    const pool = poolOf(1000, 200, 950);
    try std.testing.expectEqual(Decision{ .refuse = .at_capacity }, decide(pool, .system, 100));
}

test "the general limit is the reserve subtracted from capacity" {
    const pool = poolOf(1000, 200, 800);
    // Exactly at the general limit: an ordinary zero-cost request still fits.
    try std.testing.expect(decide(pool, .ordinary, 0).granted());
    try std.testing.expectEqual(Decision{ .refuse = .general_exhausted }, decide(pool, .ordinary, 1));
}

test "a huge request cannot wrap the committed total under the ceiling" {
    const pool = poolOf(std.math.maxInt(u64), 0, std.math.maxInt(u64) - 10);
    try std.testing.expect(!decide(pool, .system, 100).granted());
}

test "an ordinary flood never consumes the system reserve, swept" {
    // The reserve-protection property: across a range of ordinary requests, none is
    // granted that would carry the committed total past the general limit.
    const pool = poolOf(1000, 300, 600); // general limit 700
    var units: u64 = 0;
    while (units <= 400) : (units += 50) {
        if (decide(pool, .ordinary, units).granted()) {
            try std.testing.expect(pool.committed + units <= pool.generalLimit());
        }
    }
}
