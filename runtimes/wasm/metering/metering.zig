//! Accounting for what a WebAssembly guest consumes across calls: the fuel it
//! burns and the memory it reaches, against ceilings it cannot exceed.
//!
//! The engine enforces a ceiling on a single call — fuel runs out, memory will not
//! grow further, the epoch deadline fires — and reports what that call used. What it
//! does not do is remember. A guest that is called many times could stay under the
//! per-call ceiling every time while consuming without bound in aggregate, and a
//! host that only ever saw one call at a time would never notice. This is the memory
//! the engine lacks: a ledger that carries fuel and memory usage across a guest's
//! whole lifetime, so a cumulative budget is enforced as strictly as a per-call one,
//! and the high-water mark is known rather than guessed.
//!
//! The ledger decides and records; it runs no guest. A call that would carry the
//! total past its budget is refused before it runs, so the budget is a ceiling the
//! guest reaches and stops at, never one it discovers by failing.

const std = @import("std");

/// A guest's fuel and memory budget over its lifetime.
pub const Budget = struct {
    /// Total fuel the guest may burn across all its calls. Null means unmetered
    /// fuel — the per-call engine limit still applies, but no lifetime cap.
    fuel_limit: ?u64 = null,
    /// The largest linear memory, in bytes, the guest may occupy at once.
    memory_ceiling_bytes: u64,
};

/// Why a call was refused before it ran.
pub const Refusal = enum {
    /// The guest's lifetime fuel is spent; this call cannot be afforded.
    fuel_exhausted,
    /// The call declares a memory need past the guest's ceiling.
    over_memory_ceiling,
};

/// The decision to admit a call or refuse it.
pub const Admission = union(enum) {
    admit,
    refuse: Refusal,

    pub fn admitted(admission: Admission) bool {
        return admission == .admit;
    }
};

/// The running account of one guest's consumption.
pub const Ledger = struct {
    budget: Budget,
    /// Fuel burned across every call so far.
    fuel_consumed: u64 = 0,
    /// The high-water mark of memory the guest has occupied.
    peak_memory_bytes: u64 = 0,
    /// Calls admitted and run.
    calls: u64 = 0,

    pub fn init(budget: Budget) Ledger {
        return .{ .budget = budget };
    }

    /// Fuel still available over the guest's lifetime, or null if unmetered.
    pub fn fuelRemaining(ledger: Ledger) ?u64 {
        const limit = ledger.budget.fuel_limit orelse return null;
        return limit - @min(ledger.fuel_consumed, limit);
    }

    /// Decides whether a call needing at most `fuel_wanted` fuel and `memory_wanted`
    /// bytes may run, given what the guest has already used. A call the lifetime
    /// budget cannot afford is refused here rather than started and stopped.
    pub fn admit(ledger: Ledger, fuel_wanted: u64, memory_wanted: u64) Admission {
        if (memory_wanted > ledger.budget.memory_ceiling_bytes) {
            return .{ .refuse = .over_memory_ceiling };
        }
        if (ledger.budget.fuel_limit) |limit| {
            // Wide arithmetic so a large request cannot wrap the running total.
            if (@as(u128, ledger.fuel_consumed) + fuel_wanted > limit) {
                return .{ .refuse = .fuel_exhausted };
            }
        }
        return .admit;
    }

    /// Records what a call actually consumed. Fuel accrues to the lifetime total;
    /// memory updates the high-water mark, since memory is reclaimed between calls
    /// while fuel is spent for good.
    pub fn record(ledger: *Ledger, fuel_used: u64, memory_used: u64) void {
        ledger.fuel_consumed +|= fuel_used;
        if (memory_used > ledger.peak_memory_bytes) ledger.peak_memory_bytes = memory_used;
        ledger.calls += 1;
    }
};

// --- Tests ---

const testing = std.testing;

test "a call within the lifetime fuel budget is admitted and its fuel accrues" {
    var ledger = Ledger.init(.{ .fuel_limit = 1000, .memory_ceiling_bytes = 1 << 20 });
    try testing.expect(ledger.admit(400, 1024).admitted());
    ledger.record(400, 1024);
    try testing.expectEqual(@as(?u64, 600), ledger.fuelRemaining());
    try testing.expect(ledger.admit(400, 1024).admitted());
    ledger.record(400, 2048);
    try testing.expectEqual(@as(?u64, 200), ledger.fuelRemaining());
}

test "a call that would exceed the lifetime fuel budget is refused before it runs" {
    var ledger = Ledger.init(.{ .fuel_limit = 1000, .memory_ceiling_bytes = 1 << 20 });
    ledger.record(900, 0);
    const admission = ledger.admit(200, 0); // 900 + 200 > 1000
    try testing.expectEqual(Refusal.fuel_exhausted, admission.refuse);
}

test "a call demanding more memory than the ceiling is refused" {
    const ledger = Ledger.init(.{ .memory_ceiling_bytes = 1 << 16 });
    const admission = ledger.admit(0, (1 << 16) + 1);
    try testing.expectEqual(Refusal.over_memory_ceiling, admission.refuse);
}

test "unmetered fuel still enforces the memory ceiling" {
    var ledger = Ledger.init(.{ .fuel_limit = null, .memory_ceiling_bytes = 4096 });
    try testing.expect(ledger.admit(std.math.maxInt(u64), 4096).admitted());
    try testing.expect(ledger.fuelRemaining() == null);
    try testing.expectEqual(Refusal.over_memory_ceiling, ledger.admit(0, 4097).refuse);
}

test "the peak memory is the high-water mark, not the last call" {
    var ledger = Ledger.init(.{ .memory_ceiling_bytes = 1 << 20 });
    ledger.record(0, 8192);
    ledger.record(0, 2048); // lower than the peak
    try testing.expectEqual(@as(u64, 8192), ledger.peak_memory_bytes);
}

test "fuel accounting saturates rather than wrapping" {
    var ledger = Ledger.init(.{ .memory_ceiling_bytes = 1 });
    ledger.record(std.math.maxInt(u64), 0);
    ledger.record(1000, 0); // would overflow without saturation
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), ledger.fuel_consumed);
}
