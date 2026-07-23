//! Deciding whether a new connection may be opened, and when a slow consumer must
//! be throttled, so the network cannot be turned into a way to exhaust the
//! device.
//!
//! A transport stack has two finite resources that an adversary — or a mistake —
//! will spend if nothing bounds them. The first is connection slots: sockets cost
//! kernel memory and descriptors, and a principal that can open connections
//! without limit can exhaust them, denying service to everything else on the
//! device, including the system components that keep it recoverable. The second is
//! buffer memory: a connection whose consumer reads slower than the peer sends
//! will accumulate bytes, and without a cap that backlog grows until it is the
//! whole device's memory. The right answer to both is the same shape — a bound,
//! and a decision at the bound — and neither belongs in the packet path where it
//! would be reimplemented per protocol.
//!
//! This module holds those two decisions. It opens no sockets and buffers no
//! bytes; it answers whether a connection may be admitted given how many are open
//! and who is asking, and whether a connection under buffer pressure should keep
//! reading, push back on its producer, or be shed. Both are pure functions over
//! counts, testable without a network card.

const std = @import("std");

/// How important a connection is to keep the device working, which decides
/// whether it may use the reserve of slots held back from ordinary traffic.
pub const Priority = enum {
    /// An ordinary application or agent connection. Served from the general pool
    /// only, so a flood of these cannot starve the reserve.
    ordinary,
    /// A system connection the device needs to stay recoverable: an update
    /// fetch, a diagnostics upload, a management channel. May draw on the reserve
    /// when the general pool is full.
    system,

    fn mayUseReserve(priority: Priority) bool {
        return priority == .system;
    }
};

/// Why a connection was refused admission.
pub const AdmitRefusal = enum {
    /// The general pool is full and the caller is not entitled to the reserve.
    /// Ordinary traffic is shed here so that system traffic still has slots.
    pool_exhausted,
    /// Even the reserve is full: the device is at its hard connection ceiling.
    at_capacity,
};

/// The outcome of a connection-admission attempt.
pub const Admission = union(enum) {
    admit,
    refuse: AdmitRefusal,

    pub fn admitted(admission: Admission) bool {
        return admission == .admit;
    }
};

/// A bounded pool of connection slots with a reserve held back for system
/// traffic.
///
/// The total ceiling is the hard limit on open connections. A slice of it, the
/// reserve, is not available to ordinary connections at all: once the general
/// slots are gone, ordinary connections are refused while system connections can
/// still open into the reserve. This is what keeps a burst of app sockets from
/// leaving no room for the update channel that would fix the app.
pub const ConnectionPool = struct {
    /// The hard maximum number of simultaneously open connections.
    capacity: u32,
    /// How many of the capacity are reserved for system priority. Must not exceed
    /// capacity.
    reserved_for_system: u32,
    /// How many connections are open right now.
    open: u32 = 0,

    /// The number of slots ordinary traffic may use: everything but the reserve.
    fn generalLimit(pool: ConnectionPool) u32 {
        return pool.capacity - pool.reserved_for_system;
    }

    /// Decides whether a connection of the given priority may be admitted.
    ///
    /// Ordinary connections are admitted only while the open count is below the
    /// general limit, so they can never consume the reserve. System connections
    /// are admitted up to the full capacity, drawing on the reserve once the
    /// general slots are gone. At the hard ceiling everything is refused.
    pub fn admit(pool: ConnectionPool, priority: Priority) Admission {
        if (pool.open >= pool.capacity) return .{ .refuse = .at_capacity };
        if (!priority.mayUseReserve() and pool.open >= pool.generalLimit()) {
            return .{ .refuse = .pool_exhausted };
        }
        return .admit;
    }

    /// Records an admitted connection. The caller admits first; this only moves
    /// the count, saturating rather than overflowing at capacity.
    pub fn opened(pool: *ConnectionPool) void {
        if (pool.open < pool.capacity) pool.open += 1;
    }

    /// Records a closed connection, saturating at zero.
    pub fn closed(pool: *ConnectionPool) void {
        if (pool.open > 0) pool.open -= 1;
    }
};

/// What a connection under buffer pressure should do with its producer — the peer
/// or the local writer filling the buffer.
pub const Flow = enum {
    /// Keep accepting data: the buffer has comfortable room.
    proceed,
    /// Stop reading from the producer so it slows down. The bytes already
    /// buffered are kept; no data is lost, the sender is simply made to wait.
    /// This is the ordinary backpressure signal.
    apply_backpressure,
    /// The buffer is full and more data has arrived that cannot be held. It is
    /// shed rather than buffered, because buffering it is how a slow consumer
    /// turns into unbounded memory growth.
    shed,
};

/// A per-connection send-or-receive buffer with a high-water mark.
///
/// Backpressure begins at the high-water mark, well before the buffer is full, so
/// the producer is slowed with room to spare rather than after data is already
/// being dropped. Only when the buffer is genuinely full is data shed. Keeping the
/// mark below capacity is what makes backpressure a smooth signal instead of a
/// cliff.
pub const Buffer = struct {
    /// The most bytes this buffer may hold.
    capacity: u32,
    /// The level at which backpressure begins. Must not exceed capacity.
    high_water: u32,
    /// How many bytes are buffered now.
    queued: u32 = 0,

    /// Decides what to do when `incoming` more bytes are offered to a buffer
    /// already holding `queued`.
    ///
    /// If accepting them would overflow the capacity, the excess cannot be held
    /// and the offer is shed. If the buffer is at or above its high-water mark,
    /// backpressure is applied so the producer slows. Otherwise there is room and
    /// the data proceeds.
    pub fn offer(buffer: Buffer, incoming: u32) Flow {
        const after = @as(u64, buffer.queued) + incoming;
        if (after > buffer.capacity) return .shed;
        if (buffer.queued >= buffer.high_water) return .apply_backpressure;
        return .proceed;
    }

    /// Records bytes accepted into the buffer, saturating at capacity.
    pub fn enqueued(buffer: *Buffer, bytes: u32) void {
        buffer.queued = @min(buffer.capacity, buffer.queued +| bytes);
    }

    /// Records bytes drained by the consumer, saturating at zero.
    pub fn drained(buffer: *Buffer, bytes: u32) void {
        buffer.queued -|= bytes;
    }
};

test "connections admit up to the general limit and then ordinary traffic is shed" {
    var pool: ConnectionPool = .{ .capacity = 10, .reserved_for_system = 2 };
    // Eight general slots.
    pool.open = 8;
    try std.testing.expectEqual(
        Admission{ .refuse = .pool_exhausted },
        pool.admit(.ordinary),
    );
    // System traffic can still open into the reserve.
    try std.testing.expect(pool.admit(.system).admitted());
}

test "system traffic draws on the reserve up to the hard ceiling" {
    var pool: ConnectionPool = .{ .capacity = 10, .reserved_for_system = 2, .open = 10 };
    // At the hard ceiling even system traffic is refused.
    try std.testing.expectEqual(Admission{ .refuse = .at_capacity }, pool.admit(.system));
    try std.testing.expectEqual(Admission{ .refuse = .at_capacity }, pool.admit(.ordinary));
}

test "an ordinary flood never consumes the system reserve" {
    // Fill every general slot with ordinary connections; the reserve stays intact
    // for system traffic. This is the starvation property.
    var pool: ConnectionPool = .{ .capacity = 6, .reserved_for_system = 2 };
    var admitted_ordinary: u32 = 0;
    for (0..100) |_| {
        if (pool.admit(.ordinary).admitted()) {
            pool.opened();
            admitted_ordinary += 1;
        }
    }
    // Ordinary traffic got exactly the general slots, no more.
    try std.testing.expectEqual(@as(u32, 4), admitted_ordinary);
    // And the reserve is still there for system connections.
    try std.testing.expect(pool.admit(.system).admitted());
}

test "opened and closed move the count and saturate at the bounds" {
    var pool: ConnectionPool = .{ .capacity = 2, .reserved_for_system = 0 };
    pool.opened();
    pool.opened();
    pool.opened(); // saturates at capacity, does not overflow
    try std.testing.expectEqual(@as(u32, 2), pool.open);
    pool.closed();
    pool.closed();
    pool.closed(); // saturates at zero
    try std.testing.expectEqual(@as(u32, 0), pool.open);
}

test "a buffer with room lets data proceed" {
    const buffer: Buffer = .{ .capacity = 1000, .high_water = 800 };
    try std.testing.expectEqual(Flow.proceed, buffer.offer(100));
}

test "a buffer at its high-water mark applies backpressure without losing data" {
    const buffer: Buffer = .{ .capacity = 1000, .high_water = 800, .queued = 800 };
    // Room remains under capacity, so the bytes are not shed; the producer is
    // told to slow down.
    try std.testing.expectEqual(Flow.apply_backpressure, buffer.offer(100));
}

test "a full buffer sheds rather than growing unbounded" {
    const buffer: Buffer = .{ .capacity = 1000, .high_water = 800, .queued = 950 };
    // 100 more would exceed 1000; the excess cannot be held.
    try std.testing.expectEqual(Flow.shed, buffer.offer(100));
}

test "backpressure begins before the buffer is full" {
    // The whole point of a high-water mark below capacity: the producer is slowed
    // with headroom to spare, not after data is already dropped.
    const buffer: Buffer = .{ .capacity = 1000, .high_water = 800, .queued = 850 };
    try std.testing.expectEqual(Flow.apply_backpressure, buffer.offer(50));
}

test "draining relieves backpressure" {
    var buffer: Buffer = .{ .capacity = 1000, .high_water = 800, .queued = 850 };
    try std.testing.expectEqual(Flow.apply_backpressure, buffer.offer(50));
    // The consumer reads 200 bytes; the buffer drops below the mark and data
    // flows again.
    buffer.drained(200);
    try std.testing.expectEqual(Flow.proceed, buffer.offer(50));
}

test "enqueue and drain track the level and saturate" {
    var buffer: Buffer = .{ .capacity = 100, .high_water = 80 };
    buffer.enqueued(60);
    try std.testing.expectEqual(@as(u32, 60), buffer.queued);
    buffer.enqueued(60); // saturates at capacity
    try std.testing.expectEqual(@as(u32, 100), buffer.queued);
    buffer.drained(150); // saturates at zero
    try std.testing.expectEqual(@as(u32, 0), buffer.queued);
}

test "a buffer never accepts more than its capacity, swept" {
    // Whatever the level and the offer, an accepted offer never implies a level
    // over capacity: proceed and backpressure both keep the buffer bounded, and
    // only shed refuses.
    const buffer_cap: u32 = 500;
    var level: u32 = 0;
    while (level <= buffer_cap) : (level += 50) {
        const buffer: Buffer = .{ .capacity = buffer_cap, .high_water = 400, .queued = level };
        var incoming: u32 = 0;
        while (incoming <= buffer_cap) : (incoming += 50) {
            const flow = buffer.offer(incoming);
            if (flow != .shed) {
                try std.testing.expect(@as(u64, level) + incoming <= buffer_cap);
            }
        }
    }
}
