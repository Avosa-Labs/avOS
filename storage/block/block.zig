//! Deciding whether a block request is in bounds and whether a write is
//! guaranteed atomic, so a store never addresses off the end of a device and
//! never assumes a multi-block write survives a power cut.
//!
//! Storage underneath a filesystem is a flat array of fixed-size blocks, and two
//! facts about it decide whether the layers above can be correct. A block address
//! is only meaningful within the device: a request that runs off the end must be
//! refused, not clamped, because a clamped write lands on the wrong blocks and a
//! clamped read returns someone else's data. And a device guarantees atomicity
//! only up to a certain size — usually a single block — so a write that spans more
//! than that can tear on power loss, leaving some blocks new and some old. A store
//! that treats every write as atomic will corrupt itself the first time the power
//! drops mid-write; the safe design routes any write wider than the atomic unit
//! through the journal, and to do that it must know which writes those are.
//!
//! This module moves no blocks. It validates an extent against a device's geometry
//! and classifies a write as atomic or as needing the journal, as pure functions
//! over the geometry, so the layers above always know whether a request is legal
//! and whether it can be trusted to complete in one piece.

const std = @import("std");

/// A block address: an index into the device's flat block array.
pub const BlockAddress = u64;

/// The shape of a block device.
pub const Geometry = struct {
    /// The size of one block in bytes. A power of two in practice; the store reads
    /// and writes whole blocks.
    block_size_bytes: u32,
    /// How many blocks the device holds. Addresses run from 0 to this minus one.
    block_count: u64,
    /// How many consecutive blocks the device writes atomically — that is, the
    /// most blocks a single write is guaranteed to complete or not at all, even
    /// across a power loss. One for a device with no multi-block atomicity
    /// guarantee.
    atomic_blocks: u32 = 1,

    /// The last valid block address.
    pub fn lastBlock(geometry: Geometry) u64 {
        return geometry.block_count - 1;
    }
};

/// A run of consecutive blocks a request touches.
pub const Extent = struct {
    start: BlockAddress,
    /// How many blocks the extent spans. Never zero for a real request.
    count: u64,

    /// The address one past the extent's end, computed without overflow. Null if
    /// start + count would wrap, which is itself an invalid extent.
    fn endExclusive(extent: Extent) ?u128 {
        return @as(u128, extent.start) + extent.count;
    }
};

/// Why a block request was refused.
pub const Refusal = enum {
    /// The extent has zero blocks: not a request.
    empty,
    /// The extent runs off the end of the device, or its address arithmetic would
    /// overflow. Refused rather than clamped, because a clamped extent addresses
    /// the wrong blocks.
    out_of_bounds,
};

/// Whether a write is guaranteed atomic, or must be journalled to survive a tear.
pub const WriteClass = enum {
    /// The write fits within one atomic unit and is aligned to it, so the device
    /// completes it or not at all. Safe to write in place.
    atomic,
    /// The write spans more than one atomic unit, so a power loss could leave it
    /// half-applied. It must go through the journal, which can replay it to
    /// completion after a crash.
    needs_journal,
};

/// Validates an extent against a device's geometry.
///
/// A zero-length extent is not a request. Otherwise the extent must lie wholly
/// within the device: its end, computed in wide arithmetic so a near-overflow
/// start cannot wrap into a small in-bounds number, must not exceed the block
/// count. A request that fails either check is refused, never clamped to fit,
/// because a clamped extent silently addresses blocks the caller did not name.
pub fn validate(geometry: Geometry, extent: Extent) ?Refusal {
    if (extent.count == 0) return .empty;
    const end = extent.endExclusive() orelse return .out_of_bounds;
    if (end > geometry.block_count) return .out_of_bounds;
    return null;
}

/// Whether an extent is a legal request against a geometry.
pub fn isValid(geometry: Geometry, extent: Extent) bool {
    return validate(geometry, extent) == null;
}

/// Classifies a write extent as atomic or as needing the journal.
///
/// A write is atomic only if it fits within a single atomic unit and is aligned to
/// one — both, because a write of atomic-unit size that straddles a unit boundary
/// still spans two units and can tear. Any write that is larger than the atomic
/// unit, or that crosses a unit boundary, needs the journal. The extent is assumed
/// already validated; classification is about durability, not bounds.
pub fn classifyWrite(geometry: Geometry, extent: Extent) WriteClass {
    const unit = geometry.atomic_blocks;
    if (extent.count > unit) return .needs_journal;
    // Aligned means the extent sits inside one unit: its start unit and its last
    // block's unit are the same.
    const start_unit = extent.start / unit;
    const last_unit = (extent.start + extent.count - 1) / unit;
    if (start_unit != last_unit) return .needs_journal;
    return .atomic;
}

const single_block_atomic: Geometry = .{ .block_size_bytes = 4096, .block_count = 1000, .atomic_blocks = 1 };

test "an in-bounds extent is valid" {
    try std.testing.expect(isValid(single_block_atomic, .{ .start = 0, .count = 1 }));
    try std.testing.expect(isValid(single_block_atomic, .{ .start = 999, .count = 1 }));
    try std.testing.expect(isValid(single_block_atomic, .{ .start = 500, .count = 100 }));
}

test "a zero-length extent is not a request" {
    try std.testing.expectEqual(Refusal.empty, validate(single_block_atomic, .{ .start = 0, .count = 0 }).?);
}

test "an extent off the end is refused, not clamped" {
    // Block 1000 does not exist; the last is 999.
    try std.testing.expectEqual(Refusal.out_of_bounds, validate(single_block_atomic, .{ .start = 1000, .count = 1 }).?);
    // Starts in bounds but runs past the end.
    try std.testing.expectEqual(Refusal.out_of_bounds, validate(single_block_atomic, .{ .start = 999, .count = 2 }).?);
}

test "an extent whose arithmetic would overflow is out of bounds, not wrapped" {
    // A start near the top of the address space with a large count must not wrap to
    // a small in-bounds end.
    const huge: Geometry = .{ .block_size_bytes = 512, .block_count = std.math.maxInt(u64) };
    try std.testing.expectEqual(
        Refusal.out_of_bounds,
        validate(huge, .{ .start = std.math.maxInt(u64) - 1, .count = 10 }).?,
    );
}

test "the last block is addressable" {
    try std.testing.expectEqual(@as(u64, 999), single_block_atomic.lastBlock());
    try std.testing.expect(isValid(single_block_atomic, .{ .start = single_block_atomic.lastBlock(), .count = 1 }));
}

test "a single-block write is atomic on a single-block-atomic device" {
    try std.testing.expectEqual(WriteClass.atomic, classifyWrite(single_block_atomic, .{ .start = 5, .count = 1 }));
}

test "a multi-block write needs the journal when atomicity is one block" {
    try std.testing.expectEqual(WriteClass.needs_journal, classifyWrite(single_block_atomic, .{ .start = 5, .count = 2 }));
}

test "a write within a wider atomic unit is atomic" {
    // A device that writes 8 blocks atomically: a 4-block write aligned inside a
    // unit is atomic.
    const wide: Geometry = .{ .block_size_bytes = 4096, .block_count = 1000, .atomic_blocks = 8 };
    try std.testing.expectEqual(WriteClass.atomic, classifyWrite(wide, .{ .start = 0, .count = 4 }));
    try std.testing.expectEqual(WriteClass.atomic, classifyWrite(wide, .{ .start = 8, .count = 8 }));
}

test "a write straddling an atomic-unit boundary needs the journal" {
    // Even though it is only 2 blocks and the unit is 8, blocks 7 and 8 are in
    // different units, so the write can tear.
    const wide: Geometry = .{ .block_size_bytes = 4096, .block_count = 1000, .atomic_blocks = 8 };
    try std.testing.expectEqual(WriteClass.needs_journal, classifyWrite(wide, .{ .start = 7, .count = 2 }));
}

test "a write larger than the atomic unit always needs the journal" {
    const wide: Geometry = .{ .block_size_bytes = 4096, .block_count = 1000, .atomic_blocks = 8 };
    try std.testing.expectEqual(WriteClass.needs_journal, classifyWrite(wide, .{ .start = 0, .count = 9 }));
}

test "no valid write is ever misclassified as atomic when it can tear, swept" {
    // The durability property: across a range of writes on a multi-block-atomic
    // device, any classified atomic genuinely sits within one unit.
    const unit: u32 = 8;
    const wide: Geometry = .{ .block_size_bytes = 4096, .block_count = 1000, .atomic_blocks = unit };
    var start: u64 = 0;
    while (start < 32) : (start += 1) {
        var count: u64 = 1;
        while (count <= 16) : (count += 1) {
            const extent: Extent = .{ .start = start, .count = count };
            if (classifyWrite(wide, extent) == .atomic) {
                try std.testing.expect(count <= unit);
                try std.testing.expectEqual(start / unit, (start + count - 1) / unit);
            }
        }
    }
}
