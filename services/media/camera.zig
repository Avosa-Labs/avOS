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

/// The backend an adapter provides once it binds a real capture library: it enumerates cameras and
/// reports whether one can start. Held behind the interface so nothing above depends on which library.
pub const Backend = struct {
    context: *anyopaque,
    cameras_fn: *const fn (context: *anyopaque, out: []Camera) []const Camera,
    has_camera_fn: *const fn (context: *anyopaque, camera_id: u32) bool,
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
    /// fails NoBackend. Starting turns the privacy indicator on.
    pub fn start(source: *CameraSource, camera_id: u32) StartError!void {
        const backend = source.backend orelse return StartError.NoBackend;
        if (!backend.has_camera_fn(backend.context, camera_id)) return StartError.NoSuchCamera;
        source.streaming = true;
    }

    /// Stops streaming, turning the indicator off.
    pub fn stop(source: *CameraSource) void {
        source.streaming = false;
    }

    /// Whether the privacy indicator is lit. It is read from whether a stream is live at the source, so
    /// it cannot be held on without the light or off with the camera open — the indicator is the truth
    /// of the source, not a flag a principal sets.
    pub fn indicatorLit(source: CameraSource) bool {
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
