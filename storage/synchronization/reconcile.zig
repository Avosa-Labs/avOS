//! Deciding which of two versions of a record is newer, or that neither is, using
//! causal version vectors so a real conflict is never silently resolved away.
//!
//! When the same record is edited on more than one device and the devices later
//! sync, something must decide which edit survives. A wall-clock timestamp cannot:
//! device clocks drift, and "later" by a skewed clock can be causally earlier, so
//! timestamp-wins quietly discards edits. The honest answer is causal. Each record
//! carries a version vector — a per-device counter that records how many edits from
//! each device it reflects — and comparing two vectors tells the truth: if one
//! reflects everything the other does and more, it is genuinely newer and wins; if
//! each reflects an edit the other has not seen, they are concurrent, and that is a
//! real conflict that must be surfaced for a merge rather than papered over by
//! picking one. The one thing a sync must never do is silently drop a concurrent
//! edit, because that is a person's change vanishing without a trace.
//!
//! This module syncs nothing. It compares two version vectors and classifies their
//! causal relationship — equal, one dominating the other, or concurrent — and maps
//! that to which side to take or that a merge is needed, as a pure function over
//! the vectors.

const std = @import("std");

/// One device's contribution to a version vector: how many edits from that device
/// the record reflects.
pub const Entry = struct {
    device: u32,
    counter: u64,
};

/// A version vector: the per-device edit counts a record reflects. A device absent
/// from the vector is at counter zero — it has contributed no edits this record has
/// seen.
pub const Clock = struct {
    entries: []const Entry,

    /// The counter for a device, or zero if the device is absent.
    pub fn counterFor(clock: Clock, device: u32) u64 {
        for (clock.entries) |entry| {
            if (entry.device == device) return entry.counter;
        }
        return 0;
    }
};

/// The causal relationship between two version vectors.
pub const Ordering = enum {
    /// The vectors are identical: the same edits on both sides.
    equal,
    /// The first reflects everything the second does and at least one more edit:
    /// it is causally newer.
    a_dominates,
    /// The second is causally newer, by the same reasoning.
    b_dominates,
    /// Each reflects an edit the other has not seen: concurrent, a real conflict.
    concurrent,
};

/// What to do with two versions of a record.
pub const Resolution = enum {
    /// Both sides already agree; nothing to do.
    keep_either,
    /// Take the first version; it is causally newer.
    take_a,
    /// Take the second version; it is causally newer.
    take_b,
    /// The versions are concurrent; surface a conflict for a merge rather than
    /// dropping either edit.
    conflict,
};

/// Compares two version vectors and classifies their causal relationship.
///
/// It walks the union of devices named in either vector. If every one of A's
/// counters is at least B's, A reflects everything B does; likewise for B. Both
/// directions holding means the vectors are equal; one direction holding means that
/// side dominates; neither holding means each has an edit the other lacks, which is
/// concurrent. The comparison is over the union, so a device present in only one
/// vector is compared against an implicit zero in the other.
pub fn compare(a: Clock, b: Clock) Ordering {
    var a_ge_b = true;
    var b_ge_a = true;

    for (a.entries) |entry| {
        const other = b.counterFor(entry.device);
        if (entry.counter < other) a_ge_b = false;
        if (entry.counter > other) b_ge_a = false;
    }
    for (b.entries) |entry| {
        const other = a.counterFor(entry.device);
        if (entry.counter < other) b_ge_a = false;
        if (entry.counter > other) a_ge_b = false;
    }

    if (a_ge_b and b_ge_a) return .equal;
    if (a_ge_b) return .a_dominates;
    if (b_ge_a) return .b_dominates;
    return .concurrent;
}

/// Decides what to do with two versions of a record from their vectors.
///
/// Equal vectors need no action. A dominating side is taken, because it causally
/// includes the other. Concurrent vectors are reported as a conflict rather than
/// resolved by any tiebreak here, so a person's concurrent edit is never silently
/// dropped — the decision to merge or choose is made above this, with both versions
/// in hand.
pub fn resolve(a: Clock, b: Clock) Resolution {
    return switch (compare(a, b)) {
        .equal => .keep_either,
        .a_dominates => .take_a,
        .b_dominates => .take_b,
        .concurrent => .conflict,
    };
}

fn vec(entries: []const Entry) Clock {
    return .{ .entries = entries };
}

test "identical vectors are equal" {
    const a = vec(&.{ .{ .device = 1, .counter = 3 }, .{ .device = 2, .counter = 5 } });
    const b = vec(&.{ .{ .device = 1, .counter = 3 }, .{ .device = 2, .counter = 5 } });
    try std.testing.expectEqual(Ordering.equal, compare(a, b));
    try std.testing.expectEqual(Resolution.keep_either, resolve(a, b));
}

test "a strictly greater vector dominates" {
    const a = vec(&.{ .{ .device = 1, .counter = 4 }, .{ .device = 2, .counter = 5 } });
    const b = vec(&.{ .{ .device = 1, .counter = 3 }, .{ .device = 2, .counter = 5 } });
    try std.testing.expectEqual(Ordering.a_dominates, compare(a, b));
    try std.testing.expectEqual(Resolution.take_a, resolve(a, b));
    // And symmetrically.
    try std.testing.expectEqual(Ordering.b_dominates, compare(b, a));
    try std.testing.expectEqual(Resolution.take_b, resolve(b, a));
}

test "concurrent edits are a conflict, never silently resolved" {
    // A advanced device 1; B advanced device 2. Neither includes the other.
    const a = vec(&.{ .{ .device = 1, .counter = 4 }, .{ .device = 2, .counter = 5 } });
    const b = vec(&.{ .{ .device = 1, .counter = 3 }, .{ .device = 2, .counter = 6 } });
    try std.testing.expectEqual(Ordering.concurrent, compare(a, b));
    try std.testing.expectEqual(Resolution.conflict, resolve(a, b));
}

test "a device absent from one vector is treated as zero there" {
    // A knows of device 3's edit; B has never seen device 3. A dominates.
    const a = vec(&.{ .{ .device = 1, .counter = 2 }, .{ .device = 3, .counter = 1 } });
    const b = vec(&.{.{ .device = 1, .counter = 2 }});
    try std.testing.expectEqual(Ordering.a_dominates, compare(a, b));
}

test "disjoint devices that both advanced are concurrent" {
    const a = vec(&.{.{ .device = 1, .counter = 1 }});
    const b = vec(&.{.{ .device = 2, .counter = 1 }});
    try std.testing.expectEqual(Ordering.concurrent, compare(a, b));
}

test "two empty vectors are equal" {
    try std.testing.expectEqual(Ordering.equal, compare(vec(&.{}), vec(&.{})));
}

test "an empty vector is dominated by any non-empty one" {
    const a = vec(&.{.{ .device = 1, .counter = 1 }});
    try std.testing.expectEqual(Ordering.a_dominates, compare(a, vec(&.{})));
    try std.testing.expectEqual(Ordering.b_dominates, compare(vec(&.{}), a));
}

test "the relationship is symmetric and total, swept" {
    // For any pair, compare(a,b) and compare(b,a) are consistent: dominance flips,
    // equal and concurrent are symmetric. A concurrent pair is never resolved to a
    // take, so no edit is dropped.
    const samples = [_]Clock{
        vec(&.{ .{ .device = 1, .counter = 1 }, .{ .device = 2, .counter = 1 } }),
        vec(&.{ .{ .device = 1, .counter = 2 }, .{ .device = 2, .counter = 1 } }),
        vec(&.{ .{ .device = 1, .counter = 1 }, .{ .device = 2, .counter = 2 } }),
        vec(&.{.{ .device = 1, .counter = 3 }}),
        vec(&.{}),
    };
    for (samples) |a| {
        for (samples) |b| {
            const forward = compare(a, b);
            const backward = compare(b, a);
            switch (forward) {
                .equal => try std.testing.expectEqual(Ordering.equal, backward),
                .concurrent => try std.testing.expectEqual(Ordering.concurrent, backward),
                .a_dominates => try std.testing.expectEqual(Ordering.b_dominates, backward),
                .b_dominates => try std.testing.expectEqual(Ordering.a_dominates, backward),
            }
            if (forward == .concurrent) {
                try std.testing.expectEqual(Resolution.conflict, resolve(a, b));
            }
        }
    }
}
