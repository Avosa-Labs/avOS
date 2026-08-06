//! The platform audio interface: one neutral seam for capture and playback that a real audio backend
//! plugs into, honestly silent until it is bound.
//!
//! Phone screening, voice, and any sound the device makes or hears all reach the hardware through one
//! interface, so the rest of the system never speaks PipeWire, CoreAudio, or ALSA directly — a backend
//! adapter binds one of those behind this seam, exactly as the GPU device binds Vulkan. This module is
//! that seam. It fixes the shape of an audio device (a name, a direction, a stream format) and of a
//! backend (enumerate the devices, open a capture or playback stream), and it holds the honest rule
//! that matters before any C is bound: with no backend, there is no audio — enumeration is empty and a
//! stream cannot open — rather than a pretend device that silently drops every sample. Bind a backend
//! and the same calls reach real hardware with no change above the seam.
//!
//! This module drives no hardware and links no library — the bound backend does that on a realtime
//! thread, isolated behind this interface. It defines the device and stream model and the honest-until-
//! bound behaviour.

const std = @import("std");

/// Which way audio flows through a device.
pub const Direction = enum { capture, playback };

/// A stream's format: sample rate in hertz, channel count, and sample encoding.
pub const Format = struct {
    sample_rate_hz: u32,
    channels: u8,
    encoding: Encoding,

    pub const Encoding = enum { s16, f32 };

    /// Whether a format is one a stream can actually use — a real rate and at least one channel.
    pub fn valid(format: Format) bool {
        return format.sample_rate_hz >= 8_000 and format.channels >= 1;
    }
};

/// An audio device the backend exposes: a stable id, a human name, and the direction it carries.
pub const Device = struct {
    id: u32,
    name: []const u8,
    direction: Direction,
};

/// Why opening a stream did not yield one.
pub const OpenError = error{
    /// No backend is bound, so there is no hardware to reach.
    NoBackend,
    /// The requested format is not usable.
    BadFormat,
    /// The named device does not exist for the requested direction.
    NoSuchDevice,
    /// A bound backend accepted the request but the hardware stream would not open or start.
    StreamFailed,
};

/// The backend an adapter provides once it binds a real audio library: it enumerates devices and opens
/// streams. Held behind the interface so nothing above it depends on which library serves.
///
/// `devices_fn` and `can_open_fn` are always present. The three streaming hooks are optional and
/// default to null: a backend that only enumerates and validates (as every backend did before real
/// streaming was wired) leaves them null and the seam keeps its validate-only behaviour, so existing
/// `Backend{...}` literals compile and behave unchanged. A backend that opens real hardware streams
/// sets them, and the seam routes through them.
///   - `open_stream_fn` opens and starts a real stream after the seam's validation passes.
///   - `stop_stream_fn` stops and tears the stream down.
///   - `stream_live_fn` reads, at the source, whether a stream is currently running.
pub const Backend = struct {
    context: *anyopaque,
    devices_fn: *const fn (context: *anyopaque, out: []Device) []const Device,
    can_open_fn: *const fn (context: *anyopaque, device_id: u32, direction: Direction) bool,
    open_stream_fn: ?*const fn (context: *anyopaque, device_id: u32, direction: Direction, format: Format) OpenError!void = null,
    stop_stream_fn: ?*const fn (context: *anyopaque) void = null,
    stream_live_fn: ?*const fn (context: *anyopaque) bool = null,
};

/// The platform audio interface: a seam a backend binds behind. With no backend bound it is honestly
/// silent — no devices, no streams — so the absence of audio is visible, never faked.
pub const Audio = struct {
    backend: ?Backend = null,

    pub fn bind(audio: *Audio, backend: Backend) void {
        audio.backend = backend;
    }

    pub fn unbind(audio: *Audio) void {
        audio.backend = null;
    }

    pub fn available(audio: Audio) bool {
        return audio.backend != null;
    }

    /// The devices the bound backend exposes, or none when unbound. Written into `out`.
    pub fn devices(audio: Audio, out: []Device) []const Device {
        const backend = audio.backend orelse return out[0..0];
        return backend.devices_fn(backend.context, out);
    }

    /// Opens a stream on a device in a direction with a format — or a typed error. With no backend
    /// there is no hardware, so it fails NoBackend rather than pretending. A bad format or an unknown
    /// device fails likewise, before any sample flows. Once validation passes, a backend that has wired
    /// real streaming (a non-null `open_stream_fn`) actually opens and starts the hardware stream and
    /// its result stands; a backend that has not keeps the validate-only success it always gave, so the
    /// honest-until-bound contract is unchanged.
    pub fn openStream(audio: Audio, device_id: u32, direction: Direction, format: Format) OpenError!void {
        const backend = audio.backend orelse return OpenError.NoBackend;
        if (!format.valid()) return OpenError.BadFormat;
        if (!backend.can_open_fn(backend.context, device_id, direction)) return OpenError.NoSuchDevice;
        if (backend.open_stream_fn) |open| return open(backend.context, device_id, direction, format);
    }

    /// Stops a stream the bound backend has open. A backend without real streaming (no `stop_stream_fn`)
    /// has nothing running to stop, so this is a no-op — matching its validate-only open. With no
    /// backend there is nothing to stop either.
    pub fn stopStream(audio: Audio) void {
        const backend = audio.backend orelse return;
        if (backend.stop_stream_fn) |stop| stop(backend.context);
    }

    /// Whether a stream is currently live, read from the bound backend at the source. Unbound, or a
    /// backend that does not run real streams, is never live.
    pub fn streamLive(audio: Audio) bool {
        const backend = audio.backend orelse return false;
        if (backend.stream_live_fn) |live| return live(backend.context);
        return false;
    }
};

/// The path a bound backend hands captured samples across, off its realtime thread.
///
/// A capture callback runs on the audio hardware's realtime thread: it must never block, allocate, or
/// call back into general OS code, or it drops frames and glitches. So the adapter's callback does the
/// one thing that is realtime-safe — copies the block it was handed into this relay and returns — and
/// the rest of the system drains it from an ordinary thread. This is that hand-off: a bounded,
/// single-producer/single-consumer ring the callback writes and one consumer reads, with no lock on
/// either side. The producer only advances `write`, the consumer only advances `read`, and each reads
/// the other's index with an acquiring load, so a block is visible to the consumer only after its bytes
/// are fully written. It never allocates: the slots are fixed storage sized at compile time, so the
/// realtime side does no heap work. When the consumer falls behind and the ring is full the producer
/// drops the block and counts it rather than blocking the realtime thread — an honest, bounded
/// backpressure signal, never a stall in the audio callback.
pub const CaptureRelay = struct {
    /// The most bytes one captured block carries — one realtime callback's PCM. A block larger than this
    /// is dropped and counted rather than truncated, so a partial frame never reaches the consumer.
    pub const block_capacity = 4096;
    /// How many blocks the ring buffers before the producer must drop. A power of two so the slot index
    /// is a mask, not a divide.
    pub const slot_count = 32;
    const slot_mask = slot_count - 1;

    comptime {
        if (slot_count & slot_mask != 0) @compileError("slot_count must be a power of two");
    }

    /// Fixed slot storage — no allocation on the realtime path.
    slots: [slot_count][block_capacity]u8 = undefined,
    /// Bytes written into each slot, valid for a slot the consumer is reading.
    lengths: [slot_count]usize = undefined,
    /// Free-running counters: the producer advances `write`, the consumer advances `read`. The live
    /// count is `write - read`; the slot is the counter masked to the ring.
    write: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Blocks the producer had to drop because the ring was full (or the block was oversized). A count,
    /// not a stall — the realtime thread never waits on the consumer.
    dropped_blocks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init() CaptureRelay {
        return .{};
    }

    /// Producer side, called on the realtime thread: copy one captured block in and publish it. Returns
    /// false without blocking when the block does not fit the ring (full) or the slot (oversized),
    /// counting the drop. Realtime-safe: a bounded copy and two atomic operations, no lock, no allocation.
    pub fn push(relay: *CaptureRelay, samples: []const u8) bool {
        if (samples.len > block_capacity) {
            _ = relay.dropped_blocks.fetchAdd(1, .monotonic);
            return false;
        }
        const w = relay.write.load(.monotonic); // producer owns write; a plain load is enough
        const r = relay.read.load(.acquire); // observe the consumer's progress
        if (w - r >= slot_count) {
            _ = relay.dropped_blocks.fetchAdd(1, .monotonic);
            return false;
        }
        const slot: usize = @intCast(w & slot_mask);
        @memcpy(relay.slots[slot][0..samples.len], samples);
        relay.lengths[slot] = samples.len;
        relay.write.store(w + 1, .release); // publish: the block is visible only after its bytes are
        return true;
    }

    /// Consumer side, called on an ordinary thread: drain one block into `out`, or null when the ring is
    /// empty. Returns the byte length written. `out` must be at least `block_capacity` so a full block
    /// always fits.
    pub fn pop(relay: *CaptureRelay, out: []u8) ?usize {
        const r = relay.read.load(.monotonic); // consumer owns read
        const w = relay.write.load(.acquire); // observe the producer's published blocks
        if (r == w) return null; // empty
        const slot: usize = @intCast(r & slot_mask);
        const len = relay.lengths[slot];
        const n = @min(len, out.len);
        @memcpy(out[0..n], relay.slots[slot][0..n]);
        relay.read.store(r + 1, .release); // free the slot for the producer
        return n;
    }

    /// How many blocks the producer dropped for lack of room — the honest backpressure signal a caller
    /// reads to know the consumer is falling behind, never a reason the realtime thread stalled.
    pub fn dropped(relay: *const CaptureRelay) u64 {
        return relay.dropped_blocks.load(.monotonic);
    }

    /// Whether any block is waiting to be drained.
    pub fn pending(relay: *const CaptureRelay) bool {
        return relay.write.load(.acquire) != relay.read.load(.acquire);
    }
};

// --- Tests ---

const testing = std.testing;

// A stub backend standing for a bound audio library: one capture device (id 1) and one playback
// device (id 2), so the bound path is observable without real hardware.
const stub_devices = [_]Device{
    .{ .id = 1, .name = "Built-in Microphone", .direction = .capture },
    .{ .id = 2, .name = "Built-in Speakers", .direction = .playback },
};
var backend_ctx: u8 = 0;
fn stubDevices(_: *anyopaque, out: []Device) []const Device {
    const n = @min(out.len, stub_devices.len);
    @memcpy(out[0..n], stub_devices[0..n]);
    return out[0..n];
}
fn stubCanOpen(_: *anyopaque, device_id: u32, direction: Direction) bool {
    for (stub_devices) |d| {
        if (d.id == device_id and d.direction == direction) return true;
    }
    return false;
}
fn stubBackend() Backend {
    return .{ .context = &backend_ctx, .devices_fn = stubDevices, .can_open_fn = stubCanOpen };
}

test "with no backend bound there is no audio: no devices and no stream" {
    var audio = Audio{};
    try testing.expect(!audio.available());
    var buf: [4]Device = undefined;
    try testing.expectEqual(@as(usize, 0), audio.devices(&buf).len);
    try testing.expectError(OpenError.NoBackend, audio.openStream(1, .capture, .{ .sample_rate_hz = 48_000, .channels = 1, .encoding = .s16 }));
}

test "a bound backend enumerates devices and opens a valid stream" {
    var audio = Audio{};
    audio.bind(stubBackend());
    try testing.expect(audio.available());
    var buf: [4]Device = undefined;
    const found = audio.devices(&buf);
    try testing.expectEqual(@as(usize, 2), found.len);
    // Opening a real device in its direction with a valid format succeeds.
    try audio.openStream(1, .capture, .{ .sample_rate_hz = 48_000, .channels = 1, .encoding = .s16 });
    // A bad format or a device that is not there in that direction fails, before any sample.
    try testing.expectError(OpenError.BadFormat, audio.openStream(1, .capture, .{ .sample_rate_hz = 0, .channels = 1, .encoding = .s16 }));
    try testing.expectError(OpenError.NoSuchDevice, audio.openStream(1, .playback, .{ .sample_rate_hz = 48_000, .channels = 2, .encoding = .f32 }));
}

test "unbinding returns the interface to silent" {
    var audio = Audio{};
    audio.bind(stubBackend());
    audio.unbind();
    try testing.expect(!audio.available());
    var buf: [4]Device = undefined;
    try testing.expectEqual(@as(usize, 0), audio.devices(&buf).len);
}

test "the capture relay carries blocks across in order and reports empty when drained" {
    var relay = CaptureRelay.init();
    try testing.expect(!relay.pending());

    // Push three blocks and drain them: the consumer sees them in the order the producer wrote.
    try testing.expect(relay.push(&[_]u8{ 1, 2, 3 }));
    try testing.expect(relay.push(&[_]u8{ 4, 5 }));
    try testing.expect(relay.push(&[_]u8{6}));
    try testing.expect(relay.pending());

    var out: [CaptureRelay.block_capacity]u8 = undefined;
    try testing.expectEqual(@as(?usize, 3), relay.pop(&out));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, out[0..3]);
    try testing.expectEqual(@as(?usize, 2), relay.pop(&out));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, out[0..2]);
    try testing.expectEqual(@as(?usize, 1), relay.pop(&out));
    try testing.expectEqualSlices(u8, &[_]u8{6}, out[0..1]);
    try testing.expectEqual(@as(?usize, null), relay.pop(&out)); // drained
    try testing.expect(!relay.pending());
    try testing.expectEqual(@as(u64, 0), relay.dropped());
}

test "a full relay drops without blocking rather than stalling the producer" {
    var relay = CaptureRelay.init();
    // Fill every slot.
    var i: usize = 0;
    while (i < CaptureRelay.slot_count) : (i += 1) try testing.expect(relay.push(&[_]u8{0}));
    // The next push finds no room: it drops and counts, and never blocks.
    try testing.expect(!relay.push(&[_]u8{0}));
    try testing.expectEqual(@as(u64, 1), relay.dropped());
    // Draining one frees exactly one slot, so one more push succeeds.
    var out: [CaptureRelay.block_capacity]u8 = undefined;
    _ = relay.pop(&out);
    try testing.expect(relay.push(&[_]u8{0}));
    // An oversized block never truncates onto the consumer — it is dropped and counted.
    var big: [CaptureRelay.block_capacity + 1]u8 = undefined;
    try testing.expect(!relay.push(&big));
    try testing.expectEqual(@as(u64, 2), relay.dropped());
}

// The realtime hand-off under a genuine producer/consumer race: one thread pushes a long sequence of
// numbered blocks (standing in for the audio callback), another drains concurrently. The lock-free ring
// must lose nothing to corruption — every block the consumer receives is one the producer wrote, in
// order, and pushed == popped + dropped exactly. Runs on any host with threads; needs no audio hardware.
const RelayRace = struct {
    relay: *CaptureRelay,
    total: u32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn produce(ctx: *RelayRace) void {
        var seq: u32 = 0;
        while (seq < ctx.total) : (seq += 1) {
            const block: [4]u8 = @bitCast(seq); // the sequence number is the block's payload
            while (!ctx.relay.push(&block)) {} // spin until the consumer frees a slot; never blocks
        }
        ctx.done.store(true, .release);
    }
};

test "the relay hand-off loses nothing to a concurrent producer and consumer" {
    var relay = CaptureRelay.init();
    var ctx = RelayRace{ .relay = &relay, .total = 20_000 };

    const producer = try std.Thread.spawn(.{}, RelayRace.produce, .{&ctx});

    var out: [CaptureRelay.block_capacity]u8 = undefined;
    var received: u32 = 0;
    var expected: u32 = 0;
    while (true) {
        if (relay.pop(&out)) |len| {
            try testing.expectEqual(@as(usize, 4), len);
            const seq: u32 = @bitCast(out[0..4].*);
            // The producer retries until room, so every block arrives once and in order.
            try testing.expectEqual(expected, seq);
            expected += 1;
            received += 1;
        } else if (ctx.done.load(.acquire) and !relay.pending()) {
            break;
        }
    }
    producer.join();

    // Nothing was corrupted or lost: every produced block was received exactly once, in sequence.
    try testing.expectEqual(ctx.total, received);
}
