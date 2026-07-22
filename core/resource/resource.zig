//! Budgeted allocation.
//!
//! Every untrusted principal and every agent task allocates through a boundary
//! that enforces a hard ceiling and attributes what it hands out. A component
//! that can exhaust memory can deny service to the whole system, so the ceiling
//! is not advisory: an allocation that would cross it fails, and the caller
//! handles that on the normal control path.
//!
//! Allocation failure is a recoverable condition, not a panic. Code must never
//! assume allocation succeeds, and the fault-injection facility here exists so
//! that assumption gets tested rather than trusted.

const std = @import("std");
const identity = @import("../identity/identity.zig");

/// Who an allocation is charged to. Present on every budget so that a report
/// can attribute consumption rather than showing one anonymous total.
pub const Attribution = struct {
    principal: identity.PrincipalId,
    task: identity.TaskId,

    pub const unattributed: Attribution = .{
        .principal = .none,
        .task = .none,
    };
};

/// Live and historical consumption for one budget.
pub const Usage = struct {
    /// Bytes currently held.
    current_bytes: usize = 0,
    /// Highest `current_bytes` ever reached. Survives release, because the
    /// ceiling a workload needs is set by its peak, not its resting size.
    peak_bytes: usize = 0,
    /// Hard ceiling. An allocation crossing this fails.
    limit_bytes: usize,
    /// Allocations refused because they would cross the ceiling.
    refused_allocations: u64 = 0,
    /// Allocations refused by deliberate fault injection.
    injected_failures: u64 = 0,
    /// Allocations granted.
    granted_allocations: u64 = 0,

    pub fn availableBytes(usage: Usage) usize {
        return usage.limit_bytes - usage.current_bytes;
    }

    pub fn isExhausted(usage: Usage) bool {
        return usage.current_bytes >= usage.limit_bytes;
    }
};

/// Refuses allocations on a schedule so that failure paths are exercised
/// deliberately instead of only under real memory pressure.
pub const FaultInjection = struct {
    /// Refuse the allocation whose ordinal matches, counting from one. Zero
    /// disables injection.
    fail_on_allocation: u64 = 0,
    /// Refuse every allocation once armed.
    fail_all: bool = false,

    pub const disabled: FaultInjection = .{};
};

/// An allocator that enforces a ceiling and records what it hands out.
///
/// Ownership: the budget borrows `parent` and never frees it. Memory obtained
/// through `allocator()` is owned by the caller and must be released through
/// the same allocator; releasing it elsewhere would leave the accounting wrong.
///
/// Not threadsafe. One budget belongs to one task or principal, and tasks do
/// not share a budget; sharing one across threads would need a lock, which
/// would put contention on every allocation.
pub const Budget = struct {
    parent: std.mem.Allocator,
    usage: Usage,
    attribution: Attribution,
    faults: FaultInjection,
    /// Ordinal of the next allocation request, used by fault injection.
    allocation_ordinal: u64 = 0,

    pub fn init(parent: std.mem.Allocator, limit_bytes: usize, attribution: Attribution) Budget {
        return .{
            .parent = parent,
            .usage = .{ .limit_bytes = limit_bytes },
            .attribution = attribution,
            .faults = .disabled,
        };
    }

    pub fn allocator(budget: *Budget) std.mem.Allocator {
        return .{
            .ptr = budget,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Arms fault injection. Existing allocations are unaffected.
    pub fn injectFaults(budget: *Budget, faults: FaultInjection) void {
        budget.faults = faults;
    }

    /// Raises or lowers the ceiling.
    ///
    /// Lowering below current consumption is allowed and does not reclaim
    /// memory: it means no further allocation succeeds until enough is
    /// released. Reclaiming would require moving live memory the holder is
    /// still using.
    pub fn setLimit(budget: *Budget, limit_bytes: usize) void {
        budget.usage.limit_bytes = limit_bytes;
    }

    /// True when every byte handed out has been returned. A completed or
    /// cancelled task must satisfy this before its budget is discarded.
    pub fn isBalanced(budget: Budget) bool {
        return budget.usage.current_bytes == 0;
    }

    fn shouldInjectFailure(budget: *Budget) bool {
        if (budget.faults.fail_all) {
            budget.usage.injected_failures += 1;
            return true;
        }
        if (budget.faults.fail_on_allocation != 0 and
            budget.faults.fail_on_allocation == budget.allocation_ordinal)
        {
            budget.usage.injected_failures += 1;
            return true;
        }
        return false;
    }

    /// Charges `len` bytes, or reports that the ceiling refuses them.
    ///
    /// The addition is checked: a length near the representable maximum must
    /// refuse rather than wrap to a small total and appear to fit.
    fn charge(budget: *Budget, len: usize) bool {
        const proposed = std.math.add(usize, budget.usage.current_bytes, len) catch {
            budget.usage.refused_allocations += 1;
            return false;
        };
        if (proposed > budget.usage.limit_bytes) {
            budget.usage.refused_allocations += 1;
            return false;
        }
        budget.usage.current_bytes = proposed;
        budget.usage.peak_bytes = @max(budget.usage.peak_bytes, proposed);
        budget.usage.granted_allocations += 1;
        return true;
    }

    /// Releases `len` bytes.
    ///
    /// Underflow would silently create budget out of nothing, so a release
    /// larger than the outstanding total is treated as a broken invariant
    /// rather than clamped away.
    fn release(budget: *Budget, len: usize) void {
        std.debug.assert(budget.usage.current_bytes >= len);
        budget.usage.current_bytes -= len;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const budget: *Budget = @ptrCast(@alignCast(context));
        budget.allocation_ordinal += 1;
        if (budget.shouldInjectFailure()) return null;
        if (!budget.charge(len)) return null;

        const result = budget.parent.rawAlloc(len, alignment, ret_addr);
        if (result == null) {
            // The ceiling allowed it but the host did not; the charge must not
            // stand or the budget would leak capacity on every such refusal.
            budget.release(len);
            budget.usage.granted_allocations -= 1;
            budget.usage.refused_allocations += 1;
        }
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const budget: *Budget = @ptrCast(@alignCast(context));
        if (new_len > memory.len) {
            const increase = new_len - memory.len;
            if (!budget.charge(increase)) return false;
            if (!budget.parent.rawResize(memory, alignment, new_len, ret_addr)) {
                budget.release(increase);
                budget.usage.granted_allocations -= 1;
                return false;
            }
            return true;
        }

        if (!budget.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        budget.release(memory.len - new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const budget: *Budget = @ptrCast(@alignCast(context));
        if (new_len > memory.len) {
            const increase = new_len - memory.len;
            if (!budget.charge(increase)) return null;
            const result = budget.parent.rawRemap(memory, alignment, new_len, ret_addr);
            if (result == null) {
                budget.release(increase);
                budget.usage.granted_allocations -= 1;
            }
            return result;
        }

        const result = budget.parent.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) budget.release(memory.len - new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const budget: *Budget = @ptrCast(@alignCast(context));
        budget.release(memory.len);
        budget.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "allocation within the ceiling succeeds and is attributed" {
    const attribution: Attribution = .{
        .principal = .{ .value = 11 },
        .task = .{ .value = 22 },
    };
    var budget: Budget = .init(std.testing.allocator, 4096, attribution);
    const allocator = budget.allocator();

    const block = try allocator.alloc(u8, 1024);
    defer allocator.free(block);

    try std.testing.expectEqual(@as(usize, 1024), budget.usage.current_bytes);
    try std.testing.expectEqual(@as(usize, 1024), budget.usage.peak_bytes);
    try std.testing.expectEqual(@as(u64, 1), budget.usage.granted_allocations);
    try std.testing.expectEqual(@as(u128, 11), budget.attribution.principal.value);
    try std.testing.expectEqual(@as(u128, 22), budget.attribution.task.value);
}

test "an allocation crossing the ceiling is refused, not truncated" {
    var budget: Budget = .init(std.testing.allocator, 1024, .unattributed);
    const allocator = budget.allocator();

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 2048));
    try std.testing.expectEqual(@as(usize, 0), budget.usage.current_bytes);
    try std.testing.expectEqual(@as(u64, 1), budget.usage.refused_allocations);
}

test "the ceiling holds across many small allocations" {
    var budget: Budget = .init(std.testing.allocator, 1024, .unattributed);
    const allocator = budget.allocator();

    var blocks: [8][]u8 = undefined;
    var granted: usize = 0;
    for (&blocks) |*block| {
        block.* = allocator.alloc(u8, 256) catch break;
        granted += 1;
    }
    defer for (blocks[0..granted]) |block| allocator.free(block);

    try std.testing.expectEqual(@as(usize, 4), granted);
    try std.testing.expect(budget.usage.isExhausted());
    try std.testing.expectEqual(@as(usize, 0), budget.usage.availableBytes());
}

test "peak consumption survives release" {
    var budget: Budget = .init(std.testing.allocator, 8192, .unattributed);
    const allocator = budget.allocator();

    const block = try allocator.alloc(u8, 4096);
    try std.testing.expectEqual(@as(usize, 4096), budget.usage.peak_bytes);
    allocator.free(block);

    try std.testing.expectEqual(@as(usize, 0), budget.usage.current_bytes);
    try std.testing.expectEqual(@as(usize, 4096), budget.usage.peak_bytes);
    try std.testing.expect(budget.isBalanced());
}

test "accounting cannot overflow into appearing to fit" {
    var budget: Budget = .init(std.testing.allocator, std.math.maxInt(usize), .unattributed);
    const allocator = budget.allocator();

    budget.usage.current_bytes = std.math.maxInt(usize) - 16;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 4096));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize) - 16), budget.usage.current_bytes);

    budget.usage.current_bytes = 0;
}

test "injected failure refuses a specific allocation and is counted separately" {
    var budget: Budget = .init(std.testing.allocator, 1 << 20, .unattributed);
    const allocator = budget.allocator();
    budget.injectFaults(.{ .fail_on_allocation = 2 });

    const first = try allocator.alloc(u8, 64);
    defer allocator.free(first);

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 64));

    const third = try allocator.alloc(u8, 64);
    defer allocator.free(third);

    try std.testing.expectEqual(@as(u64, 1), budget.usage.injected_failures);
    try std.testing.expectEqual(@as(u64, 0), budget.usage.refused_allocations);
    try std.testing.expectEqual(@as(u64, 2), budget.usage.granted_allocations);
}

test "arming every allocation to fail exercises the caller's failure path" {
    var budget: Budget = .init(std.testing.allocator, 1 << 20, .unattributed);
    const allocator = budget.allocator();
    budget.injectFaults(.{ .fail_all = true });

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expectEqual(@as(u64, 2), budget.usage.injected_failures);
    try std.testing.expect(budget.isBalanced());
}

test "growth is charged and shrinking is refunded" {
    var budget: Budget = .init(std.testing.allocator, 4096, .unattributed);
    const allocator = budget.allocator();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, &[_]u8{0} ** 512);
    const after_growth = budget.usage.current_bytes;
    try std.testing.expect(after_growth >= 512);

    list.clearAndFree(allocator);
    try std.testing.expectEqual(@as(usize, 0), budget.usage.current_bytes);
}

test "growth beyond the ceiling is refused and leaves the budget intact" {
    var budget: Budget = .init(std.testing.allocator, 1024, .unattributed);
    const allocator = budget.allocator();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    const outcome = list.appendSlice(allocator, &[_]u8{0} ** 4096);
    try std.testing.expectError(error.OutOfMemory, outcome);
    try std.testing.expect(budget.usage.current_bytes <= 1024);
}

test "lowering the ceiling below live use blocks further allocation without reclaiming" {
    var budget: Budget = .init(std.testing.allocator, 4096, .unattributed);
    const allocator = budget.allocator();

    const block = try allocator.alloc(u8, 2048);
    defer allocator.free(block);

    budget.setLimit(1024);
    try std.testing.expectEqual(@as(usize, 2048), budget.usage.current_bytes);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
}

test "a task budget returns to balance after its work is released" {
    // The invariant a completed or cancelled task must satisfy before its
    // budget is discarded.
    var budget: Budget = .init(std.testing.allocator, 1 << 16, .{
        .principal = .{ .value = 1 },
        .task = .{ .value = 2 },
    });
    const allocator = budget.allocator();

    {
        var scratch: std.ArrayList(u32) = .empty;
        defer scratch.deinit(allocator);
        for (0..256) |value| try scratch.append(allocator, @intCast(value));
        try std.testing.expect(!budget.isBalanced());
    }

    try std.testing.expect(budget.isBalanced());
    try std.testing.expect(budget.usage.peak_bytes > 0);
}
