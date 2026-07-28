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
};

/// The backend an adapter provides once it binds a real audio library: it enumerates devices and opens
/// streams. Held behind the interface so nothing above it depends on which library serves.
pub const Backend = struct {
    context: *anyopaque,
    devices_fn: *const fn (context: *anyopaque, out: []Device) []const Device,
    can_open_fn: *const fn (context: *anyopaque, device_id: u32, direction: Direction) bool,
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
    /// device fails likewise, before any sample flows.
    pub fn openStream(audio: Audio, device_id: u32, direction: Direction, format: Format) OpenError!void {
        const backend = audio.backend orelse return OpenError.NoBackend;
        if (!format.valid()) return OpenError.BadFormat;
        if (!backend.can_open_fn(backend.context, device_id, direction)) return OpenError.NoSuchDevice;
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
