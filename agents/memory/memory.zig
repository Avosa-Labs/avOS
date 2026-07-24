//! Deciding what an agent may write to and read from its memory, keeping memory
//! bounded and carrying the taint of what was stored, so an agent cannot grow without
//! limit or launder untrusted content through recall.
//!
//! An agent remembers — facts it learned, results it computed, things a person told
//! it — so it does not start every turn blank. Memory is useful and, unmanaged,
//! dangerous in two ways. It grows: an agent that writes to memory every turn will,
//! unbounded, consume the device, so memory is a fixed budget and a write that would
//! overflow it is refused or must evict rather than expand. And it carries trust: a
//! passage from an untrusted document stored in memory is still untrusted when it is
//! recalled, so a memory entry keeps the provenance of what was written to it, and
//! recalling it does not bless it — an agent cannot store untrusted content and read
//! it back as if it were its own trusted conclusion. Memory is a bounded store that
//! preserves taint across the write-then-read, which is exactly what stops recall from
//! being a laundering channel.
//!
//! This module stores nothing. It decides whether a write fits the budget and what
//! provenance a recalled entry carries, as pure functions over the store's state.

const std = @import("std");

/// How trusted a memory entry's content is, preserved from what was written.
pub const Provenance = enum { untrusted, endorsed, trusted };

/// An agent's memory store: how much it may hold and how much it holds now.
pub const Store = struct {
    /// The most entries this agent's memory may hold.
    capacity: usize,
    /// Entries currently held.
    count: usize,
};

/// A write to memory.
pub const Entry = struct {
    /// The provenance of the content being stored. Preserved so recall cannot bless
    /// it.
    provenance: Provenance,
};

/// Why a write was refused.
pub const WriteRefusal = enum {
    /// Memory is full; the write does not fit without eviction.
    full,
};

/// The outcome of a write.
pub const WriteDecision = union(enum) {
    /// The write fits; memory now holds this many entries.
    stored: usize,
    /// The write is refused; the caller must evict before storing.
    refuse: WriteRefusal,

    pub fn stored_ok(decision: WriteDecision) bool {
        return decision == .stored;
    }
};

/// Decides whether a write fits the memory budget.
///
/// A write is accepted only while the store is below its capacity; at capacity it is
/// refused so the caller evicts rather than the store growing without bound. An
/// accepted write returns the new count.
pub fn write(store: Store, entry: Entry) WriteDecision {
    _ = entry; // provenance is preserved by the store; it does not gate the write
    if (store.count >= store.capacity) return .{ .refuse = .full };
    return .{ .stored = store.count + 1 };
}

/// The provenance a recalled entry carries.
///
/// Recall returns exactly the provenance the entry was written with — reading from
/// memory never raises trust. An untrusted passage stored and recalled is still
/// untrusted, so memory cannot be used to launder untrusted content into a trusted
/// conclusion.
pub fn recall(entry: Entry) Provenance {
    return entry.provenance;
}

test "a write below capacity is stored" {
    const store: Store = .{ .capacity = 4, .count = 2 };
    try std.testing.expectEqual(WriteDecision{ .stored = 3 }, write(store, .{ .provenance = .trusted }));
}

test "a write at capacity is refused" {
    const store: Store = .{ .capacity = 4, .count = 4 };
    try std.testing.expectEqual(WriteDecision{ .refuse = .full }, write(store, .{ .provenance = .trusted }));
}

test "recall preserves the written provenance" {
    try std.testing.expectEqual(Provenance.untrusted, recall(.{ .provenance = .untrusted }));
    try std.testing.expectEqual(Provenance.endorsed, recall(.{ .provenance = .endorsed }));
    try std.testing.expectEqual(Provenance.trusted, recall(.{ .provenance = .trusted }));
}

test "untrusted content recalled is still untrusted" {
    // The no-laundering-through-recall property: storing then recalling never blesses.
    const entry: Entry = .{ .provenance = .untrusted };
    _ = write(.{ .capacity = 8, .count = 0 }, entry);
    try std.testing.expectEqual(Provenance.untrusted, recall(entry));
}

test "memory never grows past its capacity, swept" {
    // The bounded-growth property: a stored count never exceeds capacity.
    const capacity: usize = 5;
    var count: usize = 0;
    while (count <= capacity + 2) : (count += 1) {
        const store: Store = .{ .capacity = capacity, .count = count };
        switch (write(store, .{ .provenance = .trusted })) {
            .stored => |new_count| try std.testing.expect(new_count <= capacity),
            .refuse => try std.testing.expect(count >= capacity),
        }
    }
}

test "recall equals the written provenance for every provenance, swept" {
    for (std.enums.values(Provenance)) |provenance| {
        try std.testing.expectEqual(provenance, recall(.{ .provenance = provenance }));
    }
}
