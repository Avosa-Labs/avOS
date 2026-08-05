//! The audio route a screening agent answers a call over, built on the platform audio seam.
//!
//! When an unknown caller is screened rather than rung through, an agent picks the call up: it listens
//! to the caller and speaks back, so a duplex audio path — one capture device and one playback device —
//! is what "the agent answered" actually needs. This module is that path, expressed over the neutral
//! audio seam (`services/media/audio.zig`) and nothing lower: it surveys the bound backend for a capture
//! and a playback device, reports honestly whether a real route exists, and opens or closes the pair.
//!
//! The honest rule the screening path depends on lives here: with no backend bound, or with a device
//! missing in one direction, there is no route — `availability` says exactly which, and the caller shows
//! "audio unavailable" rather than pretending an agent is listening to silence. Where the platform has
//! wired a real backend and the hardware exists, the same calls open a genuine capture and playback
//! stream, and the screening agent has a real audio route. The realtime capture thread and its lock-free
//! hand-off live inside the backend adapter, below the seam; this module only decides and opens.

const std = @import("std");
const audio = @import("audio");

/// The most devices the route surveys in one pass — far past any real host's device list.
const max_survey = 64;

/// Whether a screening audio route can be opened, and if not, exactly what is missing. The screening
/// path shows this so "audio unavailable" is specific, never a blanket excuse.
pub const Availability = enum {
    /// A capture and a playback device both exist on the bound backend — a real route can open.
    available,
    /// No backend is bound: the platform has wired no audio, so there is nothing to route over.
    no_backend,
    /// A backend is bound but exposes no capture device — the agent could speak but not listen.
    no_capture,
    /// A backend is bound but exposes no playback device — the agent could listen but not speak.
    no_playback,

    /// A short, honest description for the screening surface.
    pub fn describe(availability: Availability) []const u8 {
        return switch (availability) {
            .available => "audio route ready \u{00B7} capture + playback",
            .no_backend => "audio unavailable \u{00B7} no audio backend",
            .no_capture => "audio unavailable \u{00B7} no capture device",
            .no_playback => "audio unavailable \u{00B7} no playback device",
        };
    }
};

/// The screening audio route over a bound (or unbound) audio seam. Holds no samples and no C types — it
/// selects devices and opens seam streams; the capture samples flow through the backend's relay, below
/// the seam, never through here.
pub const ScreeningRoute = struct {
    seam: *audio.Audio,
    /// The stream shape the route opens. Voice is intelligible far below music fidelity, so mono 16-bit
    /// at 48 kHz is the default — a format every real device accepts.
    format: audio.Format = .{ .sample_rate_hz = 48_000, .channels = 1, .encoding = .s16 },
    /// The devices the last survey picked, held so opening does not re-enumerate.
    capture_id: ?u32 = null,
    playback_id: ?u32 = null,
    /// Whether this route currently holds an open pair of streams.
    opened: bool = false,

    pub fn init(seam: *audio.Audio) ScreeningRoute {
        return .{ .seam = seam };
    }

    /// Surveys the bound backend and records the first capture and first playback device it exposes.
    /// A pure read of the seam — it opens nothing.
    fn survey(route: *ScreeningRoute) void {
        route.capture_id = null;
        route.playback_id = null;
        if (!route.seam.available()) return;
        var buf: [max_survey]audio.Device = undefined;
        for (route.seam.devices(&buf)) |d| {
            switch (d.direction) {
                .capture => if (route.capture_id == null) {
                    route.capture_id = d.id;
                },
                .playback => if (route.playback_id == null) {
                    route.playback_id = d.id;
                },
            }
        }
    }

    /// Whether a real route can open, and if not, what is missing. Re-surveys the backend each call, so
    /// it tracks a device that appears or a backend that binds after construction.
    pub fn availability(route: *ScreeningRoute) Availability {
        if (!route.seam.available()) return .no_backend;
        route.survey();
        if (route.capture_id == null) return .no_capture;
        if (route.playback_id == null) return .no_playback;
        return .available;
    }

    /// Whether the screening agent has a real audio route right now.
    pub fn available(route: *ScreeningRoute) bool {
        return route.availability() == .available;
    }

    /// Opens the duplex route: the capture stream the agent listens on and the playback stream it speaks
    /// on. Fails with the seam's typed error when no route is available or a stream will not open, and
    /// leaves nothing half-open — a failed playback open tears the capture stream back down.
    pub fn openRoute(route: *ScreeningRoute) audio.OpenError!void {
        if (route.availability() != .available) return audio.OpenError.NoSuchDevice;
        const capture = route.capture_id.?;
        const playback = route.playback_id.?;
        try route.seam.openStream(capture, .capture, route.format);
        route.seam.openStream(playback, .playback, route.format) catch |err| {
            route.seam.stopStream();
            return err;
        };
        route.opened = true;
    }

    /// Closes the route, stopping both streams. Idempotent.
    pub fn closeRoute(route: *ScreeningRoute) void {
        route.seam.stopStream();
        route.opened = false;
    }

    /// Whether a route stream is actually live at the hardware, read through the seam at the source.
    pub fn live(route: *ScreeningRoute) bool {
        return route.seam.streamLive();
    }
};

// --- Tests (pure seam logic, no hardware — inert and green on a device-less CI host) ---

const testing = std.testing;

// Backends standing in for a bound audio library, so the route's decisions are observable without real
// hardware. Directions are fixed; ids are arbitrary but stable.
const duplex_devices = [_]audio.Device{
    .{ .id = 10, .name = "mic", .direction = .capture },
    .{ .id = 20, .name = "speaker", .direction = .playback },
};
const capture_only = [_]audio.Device{
    .{ .id = 10, .name = "mic", .direction = .capture },
};
const playback_only = [_]audio.Device{
    .{ .id = 20, .name = "speaker", .direction = .playback },
};

fn devicesFrom(comptime set: []const audio.Device) fn (*anyopaque, []audio.Device) []const audio.Device {
    return struct {
        fn f(_: *anyopaque, out: []audio.Device) []const audio.Device {
            const n = @min(out.len, set.len);
            @memcpy(out[0..n], set[0..n]);
            return out[0..n];
        }
    }.f;
}
fn canOpenFrom(comptime set: []const audio.Device) fn (*anyopaque, u32, audio.Direction) bool {
    return struct {
        fn f(_: *anyopaque, id: u32, dir: audio.Direction) bool {
            for (set) |d| if (d.id == id and d.direction == dir) return true;
            return false;
        }
    }.f;
}
var ctx: u8 = 0;
fn backendFrom(comptime set: []const audio.Device) audio.Backend {
    return .{ .context = &ctx, .devices_fn = devicesFrom(set), .can_open_fn = canOpenFrom(set) };
}

test "with no backend bound the screening route is honestly unavailable" {
    var seam = audio.Audio{};
    var route = ScreeningRoute.init(&seam);
    try testing.expectEqual(Availability.no_backend, route.availability());
    try testing.expect(!route.available());
    // Opening refuses rather than pretending an agent is on the line.
    try testing.expectError(audio.OpenError.NoSuchDevice, route.openRoute());
    try testing.expect(!route.live());
}

test "a duplex backend gives the screening agent a real route" {
    var seam = audio.Audio{};
    seam.bind(backendFrom(&duplex_devices));
    var route = ScreeningRoute.init(&seam);
    try testing.expectEqual(Availability.available, route.availability());
    try testing.expect(route.available());
    // The route selected one device per direction from the backend's set.
    try testing.expectEqual(@as(?u32, 10), route.capture_id);
    try testing.expectEqual(@as(?u32, 20), route.playback_id);
    // Opening the pair succeeds (the stub validates without a real stream), and closing is clean.
    try route.openRoute();
    route.closeRoute();
    try testing.expect(!route.live());
}

test "a one-direction backend names exactly what is missing" {
    var seam = audio.Audio{};
    var route = ScreeningRoute.init(&seam);

    seam.bind(backendFrom(&capture_only));
    try testing.expectEqual(Availability.no_playback, route.availability());
    try testing.expectError(audio.OpenError.NoSuchDevice, route.openRoute());

    seam.bind(backendFrom(&playback_only));
    try testing.expectEqual(Availability.no_capture, route.availability());
    try testing.expectError(audio.OpenError.NoSuchDevice, route.openRoute());
}

test "each availability describes itself honestly for the surface" {
    try testing.expect(std.mem.indexOf(u8, Availability.available.describe(), "ready") != null);
    for ([_]Availability{ .no_backend, .no_capture, .no_playback }) |a| {
        try testing.expect(std.mem.indexOf(u8, a.describe(), "unavailable") != null);
    }
}
