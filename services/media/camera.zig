//! The platform camera interface: one neutral seam for camera frames that a real capture backend plugs
//! into, dark until it is bound, with the privacy indicator wired at the frame source so it cannot be
//! bypassed.
//!
//! Camera-Lens, Describe, and Capture all receive frames through one interface, so nothing above it
//! speaks V4L2, AVFoundation, or an Android HAL directly — a backend adapter binds one of those behind
//! this seam, exactly as the GPU device binds Vulkan. This module is that seam. It fixes the shape of a
//! camera and of a frame, and of a backend that enumerates cameras and starts a stream, and it fixes
//! two honest rules. With no backend there is no camera — enumeration is empty and a stream cannot
//! start — rather than a fake feed. And whenever a stream is live, the privacy indicator is on: it is
//! read from whether the frame source is delivering, at the source, so no principal above the seam can
//! hold the camera open with the light off.
//!
//! This module drives no hardware and links no library — the bound backend does that. It defines the
//! camera and frame model, the honest-until-bound behaviour, and the unbypassable indicator.

const std = @import("std");

/// A pixel format a frame is delivered in.
pub const PixelFormat = enum { nv12, yuyv, rgba };

/// A frame the camera delivers: its dimensions and pixel format. The pixels themselves are the
/// backend's buffer, consumed by the compositor or the vision model, not held here.
pub const Frame = struct {
    width: u16,
    height: u16,
    format: PixelFormat,
};

/// A camera the backend exposes: a stable id and a human name.
pub const Camera = struct {
    id: u32,
    name: []const u8,
};

/// Why starting a stream did not begin one.
pub const StartError = error{
    /// No backend is bound, so there is no camera to reach.
    NoBackend,
    /// The named camera does not exist.
    NoSuchCamera,
};

/// The backend an adapter provides once it binds a real capture library. Enumeration is always
/// present; real frame streaming is optional, so an adapter that only answers "which cameras exist"
/// (like the first enumeration-only adapters) still binds, and one that carries a live capture session
/// fills the streaming functions in:
///   - `start_stream_fn` starts a real capture session on a camera, validating it exists.
///   - `stop_stream_fn` stops the session and tears it down.
///   - `stream_live_fn` reads, at the source, whether a session is currently delivering — the truth
///     the privacy indicator is read from, so it cannot be held on without the light.
///   - `latest_frame_fn` reports the most recent delivered frame's shape, or false before any frame
///     has arrived. The pixels stay in the backend's buffer; only the frame's shape crosses the seam.
/// Held behind the interface so nothing above depends on which library.
pub const Backend = struct {
    context: *anyopaque,
    cameras_fn: *const fn (context: *anyopaque, out: []Camera) []const Camera,
    has_camera_fn: *const fn (context: *anyopaque, camera_id: u32) bool,
    start_stream_fn: ?*const fn (context: *anyopaque, camera_id: u32) StartError!void = null,
    stop_stream_fn: ?*const fn (context: *anyopaque) void = null,
    stream_live_fn: ?*const fn (context: *anyopaque) bool = null,
    latest_frame_fn: ?*const fn (context: *anyopaque, out: *Frame) bool = null,
};

/// The platform camera interface: a seam a backend binds behind. Dark until bound, and while a stream
/// is live the privacy indicator is on, read at the source.
pub const CameraSource = struct {
    backend: ?Backend = null,
    streaming: bool = false,

    pub fn bind(source: *CameraSource, backend: Backend) void {
        source.backend = backend;
    }

    pub fn unbind(source: *CameraSource) void {
        source.streaming = false;
        source.backend = null;
    }

    pub fn available(source: CameraSource) bool {
        return source.backend != null;
    }

    /// The cameras the bound backend exposes, or none when unbound.
    pub fn cameras(source: CameraSource, out: []Camera) []const Camera {
        const backend = source.backend orelse return out[0..0];
        return backend.cameras_fn(backend.context, out);
    }

    /// Starts streaming from a camera, or a typed error. With no backend there is no camera, so it
    /// fails NoBackend. A backend with real streaming (a non-null `start_stream_fn`) starts an actual
    /// capture session, which validates the camera itself; an enumeration-only backend falls back to
    /// checking the camera exists. Either way, starting turns the privacy indicator on.
    pub fn start(source: *CameraSource, camera_id: u32) StartError!void {
        const backend = source.backend orelse return StartError.NoBackend;
        if (backend.start_stream_fn) |start_stream| {
            try start_stream(backend.context, camera_id);
        } else if (!backend.has_camera_fn(backend.context, camera_id)) {
            return StartError.NoSuchCamera;
        }
        source.streaming = true;
    }

    /// Stops streaming, turning the indicator off. A backend with a real session has it torn down.
    pub fn stop(source: *CameraSource) void {
        if (source.backend) |backend| {
            if (backend.stop_stream_fn) |stop_stream| stop_stream(backend.context);
        }
        source.streaming = false;
    }

    /// The most recent frame's shape, or null before any frame has arrived (or with no streaming
    /// backend bound). The pixels are not carried here — only the frame's dimensions and format, for a
    /// consumer to size its work against.
    pub fn latestFrame(source: CameraSource) ?Frame {
        const backend = source.backend orelse return null;
        const latest = backend.latest_frame_fn orelse return null;
        var frame: Frame = undefined;
        return if (latest(backend.context, &frame)) frame else null;
    }

    /// Whether the privacy indicator is lit. When a real streaming backend is bound it is read from
    /// the source itself (`stream_live_fn`), so it cannot be held on without the light or off with the
    /// camera open; otherwise it reflects whether a stream was started. The indicator is the truth of
    /// the source, not a flag a principal sets.
    pub fn indicatorLit(source: CameraSource) bool {
        if (source.backend) |backend| {
            if (backend.stream_live_fn) |live| return live(backend.context);
        }
        return source.streaming;
    }
};

// --- Tests ---

const testing = std.testing;

const stub_cameras = [_]Camera{
    .{ .id = 1, .name = "Front camera" },
    .{ .id = 2, .name = "Rear camera" },
};
var backend_ctx: u8 = 0;
fn stubCameras(_: *anyopaque, out: []Camera) []const Camera {
    const n = @min(out.len, stub_cameras.len);
    @memcpy(out[0..n], stub_cameras[0..n]);
    return out[0..n];
}
fn stubHasCamera(_: *anyopaque, camera_id: u32) bool {
    for (stub_cameras) |c| {
        if (c.id == camera_id) return true;
    }
    return false;
}
fn stubBackend() Backend {
    return .{ .context = &backend_ctx, .cameras_fn = stubCameras, .has_camera_fn = stubHasCamera };
}

test "with no backend the camera is dark: no cameras, no stream, indicator off" {
    var source = CameraSource{};
    try testing.expect(!source.available());
    var buf: [4]Camera = undefined;
    try testing.expectEqual(@as(usize, 0), source.cameras(&buf).len);
    try testing.expectError(StartError.NoBackend, source.start(1));
    try testing.expect(!source.indicatorLit());
}

test "a bound backend enumerates cameras and starting lights the indicator" {
    var source = CameraSource{};
    source.bind(stubBackend());
    var buf: [4]Camera = undefined;
    try testing.expectEqual(@as(usize, 2), source.cameras(&buf).len);
    // Before starting, the indicator is off.
    try testing.expect(!source.indicatorLit());
    try source.start(1);
    // Streaming lights the indicator, read at the source.
    try testing.expect(source.indicatorLit());
    source.stop();
    try testing.expect(!source.indicatorLit());
    // An unknown camera cannot start.
    try testing.expectError(StartError.NoSuchCamera, source.start(99));
}

test "unbinding stops the stream and clears the indicator" {
    var source = CameraSource{};
    source.bind(stubBackend());
    try source.start(1);
    source.unbind();
    try testing.expect(!source.available());
    try testing.expect(!source.indicatorLit()); // the light cannot survive the source going away
}

// A streaming stub standing for a real capture backend: it runs a session, reports the indicator from
// the session's own state, and delivers a frame once running — so the streaming seam is observable
// without a camera.
const StreamStub = struct {
    running: bool = false,
    fn cameras(_: *anyopaque, out: []Camera) []const Camera {
        return stubCameras(undefined, out);
    }
    fn hasCamera(_: *anyopaque, camera_id: u32) bool {
        return stubHasCamera(undefined, camera_id);
    }
    fn startStream(context: *anyopaque, camera_id: u32) StartError!void {
        const self: *StreamStub = @ptrCast(@alignCast(context));
        if (!stubHasCamera(undefined, camera_id)) return StartError.NoSuchCamera;
        self.running = true;
    }
    fn stopStream(context: *anyopaque) void {
        const self: *StreamStub = @ptrCast(@alignCast(context));
        self.running = false;
    }
    fn streamLive(context: *anyopaque) bool {
        const self: *StreamStub = @ptrCast(@alignCast(context));
        return self.running;
    }
    fn latestFrame(context: *anyopaque, out: *Frame) bool {
        const self: *StreamStub = @ptrCast(@alignCast(context));
        if (!self.running) return false; // no frame before a session is delivering
        out.* = .{ .width = 1280, .height = 720, .format = .nv12 };
        return true;
    }
    fn backend(self: *StreamStub) Backend {
        return .{
            .context = self,
            .cameras_fn = cameras,
            .has_camera_fn = hasCamera,
            .start_stream_fn = startStream,
            .stop_stream_fn = stopStream,
            .stream_live_fn = streamLive,
            .latest_frame_fn = latestFrame,
        };
    }
};

test "a streaming backend delivers frames and drives the indicator from the live session" {
    var stub = StreamStub{};
    var source = CameraSource{};
    source.bind(stub.backend());

    // Before starting: the session is not live, so no frame and the indicator is off — read from the
    // source, not a local flag.
    try testing.expect(!source.indicatorLit());
    try testing.expectEqual(@as(?Frame, null), source.latestFrame());

    // Starting runs the real session: the indicator lights from the source and a frame is delivered.
    try source.start(1);
    try testing.expect(source.indicatorLit());
    const frame = source.latestFrame() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 1280), frame.width);
    try testing.expectEqual(PixelFormat.nv12, frame.format);

    // Stopping tears the session down: the indicator follows the source off, and frames stop.
    source.stop();
    try testing.expect(!source.indicatorLit());
    try testing.expectEqual(@as(?Frame, null), source.latestFrame());

    // An unknown camera cannot start a session.
    try testing.expectError(StartError.NoSuchCamera, source.start(99));
}
