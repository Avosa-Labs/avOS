//! Bounded collections, because an unbounded one is a fault waiting for load.
//!
//! The platform forbids unbounded queues, and this is where that rule is made
//! concrete. Every structure here has a fixed capacity chosen when it is
//! created, and a producer that outruns a consumer meets backpressure — a
//! refusal — rather than growing the structure until the device runs out of
//! memory and something unrelated fails. The failure of a full queue is visible
//! and local; the failure of an unbounded one arrives later, elsewhere, as an
//! allocation that could not be satisfied.
//!
//! Two structures cover the cases the concurrency model names. A bounded queue
//! carries work that must all be processed, and refuses new work when full. A
//! coalescing slot carries a value where only the latest matters — a cursor
//! position, a battery level, a sensor reading — and a new value overwrites the
//! old rather than queueing behind it, because delivering a stale intermediate
//! is worse than skipping it.

const std = @import("std");

pub const Error = error{
    /// The queue is full. The producer must wait, not the queue grow.
    Full,
};

/// A fixed-capacity first-in-first-out queue.
///
/// The capacity is a compile-time constant, so the storage is inline and no
/// allocation happens on the hot path. A push to a full queue is refused, which
/// is the backpressure the concurrency model requires: the producer learns
/// immediately that it is outrunning the consumer.
pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0);
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        /// Adds an item, or refuses if full.
        pub fn push(queue: *Self, item: T) Error!void {
            if (queue.len == capacity) return error.Full;
            const tail = (queue.head + queue.len) % capacity;
            queue.items[tail] = item;
            queue.len += 1;
        }

        /// Removes and returns the oldest item, or null if empty.
        pub fn pop(queue: *Self) ?T {
            if (queue.len == 0) return null;
            const item = queue.items[queue.head];
            queue.head = (queue.head + 1) % capacity;
            queue.len -= 1;
            return item;
        }

        /// The oldest item without removing it, or null if empty.
        pub fn peek(queue: *const Self) ?T {
            if (queue.len == 0) return null;
            return queue.items[queue.head];
        }

        pub fn isFull(queue: *const Self) bool {
            return queue.len == capacity;
        }

        pub fn isEmpty(queue: *const Self) bool {
            return queue.len == 0;
        }

        pub fn count(queue: *const Self) usize {
            return queue.len;
        }

        /// How much room remains. A producer can size a burst against this rather
        /// than pushing until it is refused.
        pub fn remaining(queue: *const Self) usize {
            return capacity - queue.len;
        }
    };
}

/// A slot holding at most the latest value.
///
/// For state where only the current value matters. Setting it replaces whatever
/// was there and marks it fresh; taking it returns the value and marks it
/// consumed. A producer that sets faster than the consumer takes does not build
/// a backlog — the consumer simply sees the newest value when it looks, which is
/// the correct behaviour for a cursor, a level, or a reading.
pub fn CoalescingSlot(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T = undefined,
        fresh: bool = false,
        /// How many values were overwritten before being taken. Reported so a
        /// consumer can tell it is falling behind, which is information an
        /// unbounded queue would have hidden by simply growing.
        coalesced: u64 = 0,

        /// Stores a value, replacing any unconsumed one.
        pub fn set(slot: *Self, value: T) void {
            if (slot.fresh) slot.coalesced += 1;
            slot.value = value;
            slot.fresh = true;
        }

        /// Returns the latest value and marks it consumed, or null if there is
        /// nothing fresh since the last take.
        pub fn take(slot: *Self) ?T {
            if (!slot.fresh) return null;
            slot.fresh = false;
            return slot.value;
        }

        pub fn hasValue(slot: *const Self) bool {
            return slot.fresh;
        }
    };
}

test "a bounded queue is first in, first out" {
    var queue: BoundedQueue(u32, 4) = .{};
    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "a full queue refuses rather than growing" {
    var queue: BoundedQueue(u32, 2) = .{};
    try queue.push(1);
    try queue.push(2);
    // The backpressure: the producer is told it is outrunning the consumer,
    // rather than the queue consuming memory until something else fails.
    try std.testing.expectError(error.Full, queue.push(3));
    try std.testing.expect(queue.isFull());
}

test "a queue reused across the wrap point stays correct" {
    var queue: BoundedQueue(u32, 3) = .{};
    // Fill, drain part way, and refill so the internal indices wrap. A ring that
    // mishandled the wrap would corrupt or reorder here.
    try queue.push(1);
    try queue.push(2);
    _ = queue.pop();
    _ = queue.pop();
    try queue.push(3);
    try queue.push(4);
    try queue.push(5);
    try std.testing.expectError(error.Full, queue.push(6));
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, 4), queue.pop());
    try std.testing.expectEqual(@as(?u32, 5), queue.pop());
}

test "peek does not remove" {
    var queue: BoundedQueue(u8, 2) = .{};
    try queue.push(7);
    try std.testing.expectEqual(@as(?u8, 7), queue.peek());
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(?u8, 7), queue.pop());
}

test "remaining tracks the space left" {
    var queue: BoundedQueue(u8, 3) = .{};
    try std.testing.expectEqual(@as(usize, 3), queue.remaining());
    try queue.push(1);
    try std.testing.expectEqual(@as(usize, 2), queue.remaining());
}

test "an empty queue reports empty and pops null" {
    var queue: BoundedQueue(u8, 1) = .{};
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u8, null), queue.pop());
    try std.testing.expectEqual(@as(?u8, null), queue.peek());
}

test "a coalescing slot keeps only the latest value" {
    var slot: CoalescingSlot(u32) = .{};
    slot.set(1);
    slot.set(2);
    slot.set(3);
    // Only the newest is delivered; the intermediates are gone, which is correct
    // for a value where only the current one matters.
    try std.testing.expectEqual(@as(?u32, 3), slot.take());
    try std.testing.expectEqual(@as(?u32, null), slot.take());
}

test "a coalescing slot reports how far behind the consumer fell" {
    var slot: CoalescingSlot(u32) = .{};
    slot.set(1);
    slot.set(2);
    slot.set(3);
    _ = slot.take();
    // Two values were overwritten before the take: information an unbounded
    // queue would have hidden by simply growing.
    try std.testing.expectEqual(@as(u64, 2), slot.coalesced);
}

test "a coalescing slot taken between sets does not count as coalesced" {
    var slot: CoalescingSlot(u32) = .{};
    slot.set(1);
    _ = slot.take();
    slot.set(2);
    _ = slot.take();
    // Each value was consumed before the next arrived, so nothing was dropped.
    try std.testing.expectEqual(@as(u64, 0), slot.coalesced);
}

test "an empty coalescing slot takes null" {
    var slot: CoalescingSlot(u8) = .{};
    try std.testing.expect(!slot.hasValue());
    try std.testing.expectEqual(@as(?u8, null), slot.take());
}

test "a queue of one behaves" {
    // The smallest capacity, where full and empty are one push apart, is where
    // off-by-one errors hide.
    var queue: BoundedQueue(u8, 1) = .{};
    try queue.push(9);
    try std.testing.expect(queue.isFull());
    try std.testing.expectError(error.Full, queue.push(10));
    try std.testing.expectEqual(@as(?u8, 9), queue.pop());
    try std.testing.expect(queue.isEmpty());
    try queue.push(11);
    try std.testing.expectEqual(@as(?u8, 11), queue.pop());
}

test "a full-drain-full cycle never exceeds capacity" {
    // Stress the invariant: many cycles, the count never passes capacity and the
    // order is always preserved.
    var queue: BoundedQueue(usize, 8) = .{};
    var expected: usize = 0;
    var next: usize = 0;
    for (0..1000) |_| {
        while (queue.remaining() > 0) {
            queue.push(next) catch unreachable;
            next += 1;
        }
        try std.testing.expect(queue.count() <= 8);
        while (queue.pop()) |value| {
            try std.testing.expectEqual(expected, value);
            expected += 1;
        }
    }
}
