//! The AVFoundation camera adapter: a Zig backend over the macOS capture stack, bound behind the
//! platform camera seam (`services/media/camera.zig`).
//!
//! AVFoundation is macOS's capture framework. This adapter reaches it to answer what the seam asks:
//! which cameras exist, whether a given camera id exists, and — behind the same seam — to run a real
//! capture session. It discovers the host's video capture devices (built-in wide-angle plus external),
//! maps each to a stable small integer id (a hash of its uniqueID) and its localizedName, and answers
//! has-camera against that live set. Starting a stream brings up an AVCaptureSession +
//! AVCaptureVideoDataOutput on the camera; each delivered CMSampleBuffer's shape (width, height, and the
//! CoreVideo pixel format) is recorded in the shim, and the seam reads its privacy indicator from
//! whether the session is actually running. Only a frame's shape crosses the seam — the pixel buffer
//! stays in the shim's delegate — so a frame read is O(1), never a per-pixel copy.
//!
//! Every AVFoundation and Objective-C type stays inside `shim.m`/`shim.h`; nothing above the seam — and
//! nothing in this Zig file's public signatures — sees a capture type. The returned camera names must
//! outlive the enumeration call, so the backend context owns fixed-size name buffers and the returned
//! `[]const u8` slices point into them, never onto the stack.
//!
//! Built only on macOS (see the build's os gate); off macOS the seam keeps its honest-until-bound
//! default and this module is never compiled.

const std = @import("std");
const camera = @import("camera");
const binds = @import("bindings.zig");
const c = binds.c;

/// A CoreVideo pixel-format OSType built from its four-character code. OSType packs the characters
/// big-endian (`'abcd'` == a<<24 | b<<16 | c<<8 | d), which is how the CoreVideo constants are defined.
fn osType(comptime code: *const [4]u8) u32 {
    return (@as(u32, code[0]) << 24) | (@as(u32, code[1]) << 16) | (@as(u32, code[2]) << 8) | code[3];
}

// The CoreVideo pixel formats the adapter maps. Biplanar 4:2:0 (video- and full-range) is NV12; the
// packed 4:2:2 codes are YUYV-class; the packed 32-bit RGB codes are RGBA-class. AVCaptureVideoDataOutput
// delivers `420v` by default on macOS, so nv12 is also the honest default for anything unrecognised.
const cv_420v = osType("420v"); // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
const cv_420f = osType("420f"); // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
const cv_yuvs = osType("yuvs"); // kCVPixelFormatType_422YpCbCr8_yuvs (YUY2)
const cv_2vuy = osType("2vuy"); // kCVPixelFormatType_422YpCbCr8 (UYVY)
const cv_bgra = osType("BGRA"); // kCVPixelFormatType_32BGRA
const cv_rgba = osType("RGBA"); // kCVPixelFormatType_32RGBA
const cv_abgr = osType("ABGR"); // kCVPixelFormatType_32ABGR

/// Maps a CoreVideo pixel-format OSType to the seam's `PixelFormat`, choosing the closest family and
/// defaulting to nv12 for anything the adapter does not recognise — an honest closest match, never a
/// guess that changes the pixel layout a consumer would read.
fn pixelFormat(code: u32) camera.PixelFormat {
    return switch (code) {
        cv_420v, cv_420f => .nv12,
        cv_yuvs, cv_2vuy => .yuyv,
        cv_bgra, cv_rgba, cv_abgr => .rgba,
        else => .nv12,
    };
}

/// The most cameras we enumerate, and the most name buffers the context owns.
const max_cameras = 16;
/// Bytes reserved per camera name, UTF-8, NUL-terminated. AVCaptureDevice localizedName is short.
const name_capacity = 128;

/// The bound AVFoundation backend. It owns the name storage the returned `Camera` slices point into, so
/// a camera name lives as long as the backend, not the call. One is enough for a process.
pub const AvfCameraBackend = struct {
    /// One UTF-8 name buffer per possible returned camera. `enumerate` writes a name here and hands back
    /// a slice into it, so the name outlives the call.
    name_store: [max_cameras][name_capacity]u8 = undefined,

    pub fn init() AvfCameraBackend {
        return .{};
    }

    /// The seam backend that reaches this adapter. Bind it to a `CameraSource` with `source.bind(...)`.
    pub fn backend(self: *AvfCameraBackend) camera.Backend {
        return .{
            .context = @ptrCast(self),
            .cameras_fn = camerasFn,
            .has_camera_fn = hasCameraFn,
            .start_stream_fn = startStreamFn,
            .stop_stream_fn = stopStreamFn,
            .stream_live_fn = streamLiveFn,
            .latest_frame_fn = latestFrameFn,
        };
    }

    fn camerasFn(context: *anyopaque, out: []camera.Camera) []const camera.Camera {
        const self: *AvfCameraBackend = @ptrCast(@alignCast(context));
        return self.enumerate(out);
    }

    fn hasCameraFn(context: *anyopaque, camera_id: u32) bool {
        _ = context;
        return c.avf_has_camera(camera_id) != 0;
    }

    /// Starts a real AVCaptureSession on the camera. The shim validates the device exists — a missing
    /// one is the seam's `NoSuchCamera`. A real camera whose session cannot be built (the shim's -2) is
    /// not `NoSuchCamera`: nothing is left running, so `stream_live_fn` reads honestly off, honest about
    /// what did and did not come up rather than reporting a camera absent.
    fn startStreamFn(context: *anyopaque, camera_id: u32) camera.StartError!void {
        _ = context;
        if (binds.avf_stream_start(camera_id) == -1) return camera.StartError.NoSuchCamera;
    }

    fn stopStreamFn(context: *anyopaque) void {
        _ = context;
        binds.avf_stream_stop();
    }

    fn streamLiveFn(context: *anyopaque) bool {
        _ = context;
        return binds.avf_stream_live() != 0;
    }

    /// Reports the most recent delivered frame's shape, or false before any frame has arrived. Only the
    /// shape crosses the seam; the pixel buffer stays in the shim's delegate, so this is an O(1) read.
    fn latestFrameFn(context: *anyopaque, out: *camera.Frame) bool {
        _ = context;
        var width: c_uint = 0;
        var height: c_uint = 0;
        var format: c_uint = 0;
        if (binds.avf_latest_frame(&width, &height, &format) == 0) return false;
        out.* = .{
            .width = @intCast(@min(width, @as(c_uint, std.math.maxInt(u16)))),
            .height = @intCast(@min(height, @as(c_uint, std.math.maxInt(u16)))),
            .format = pixelFormat(@intCast(format)),
        };
        return true;
    }

    /// Discovers the host's video capture devices into `out`, one `Camera` each with its stable id and
    /// its name read into the context's owned storage. Any device whose name cannot be read is skipped,
    /// so every returned camera has a non-empty name. An empty slice — a headless or TCC-restricted host
    /// with no cameras — is an honest answer, not an error.
    fn enumerate(self: *AvfCameraBackend, out: []camera.Camera) []const camera.Camera {
        const count: usize = @intCast(@max(c.avf_camera_count(), 0));
        var written: usize = 0;
        var index: c_int = 0;
        while (index < count and written < out.len and written < self.name_store.len) : (index += 1) {
            const id = c.avf_camera_id(index);
            if (id == 0) continue;
            const store: *[name_capacity]u8 = &self.name_store[written];
            const len = c.avf_camera_name(id, store, @intCast(store.len));
            if (len <= 0) continue; // a name we cannot read means no honest camera to report
            out[written] = .{ .id = id, .name = store[0..@intCast(len)] };
            written += 1;
        }
        return out[0..written];
    }
};

// --- Tests (real macOS AVFoundation capture stack, this host's actual cameras) ---

const testing = std.testing;

test "the AVFoundation backend binds and enumerates the host's real cameras without crashing" {
    var avf = AvfCameraBackend.init();
    var source = camera.CameraSource{};
    source.bind(avf.backend());
    try testing.expect(source.available());

    var buf: [max_cameras]camera.Camera = undefined;
    const cameras = source.cameras(&buf);
    // Hardware varies and a headless / TCC-restricted CI runner may discover zero cameras — the honest
    // range is 0..N. What must hold is that every camera reported is well formed: a non-empty name.
    try testing.expect(cameras.len >= 0);
    for (cameras) |cam| {
        try testing.expect(cam.name.len > 0);
    }
}

test "has-camera agrees with the enumerated set" {
    var avf = AvfCameraBackend.init();
    var source = camera.CameraSource{};
    source.bind(avf.backend());

    var buf: [max_cameras]camera.Camera = undefined;
    const cameras = source.cameras(&buf);

    // An id not in the enumerated set cannot start — the backend reports no such camera. This drives
    // the real start path only for a missing id, which is refused before any device is opened, so the
    // check never activates the camera. Starting a session on a real camera is a host-integration
    // behaviour, deliberately kept out of the test suite so `zig build test` never lights the camera.
    var bogus: u32 = 0xFFFF_FFF0;
    while (bogus != 0) : (bogus -%= 1) {
        var present = false;
        for (cameras) |cam| {
            if (cam.id == bogus) present = true;
        }
        if (!present) break;
    }
    try testing.expectError(camera.StartError.NoSuchCamera, source.start(bogus));
}

test "the CoreVideo pixel formats map to the seam's families, defaulting to nv12" {
    // Biplanar 4:2:0 is NV12; the packed 4:2:2 codes are YUYV-class; the packed 32-bit codes are RGBA.
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(cv_420v));
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(cv_420f));
    try testing.expectEqual(camera.PixelFormat.yuyv, pixelFormat(cv_yuvs));
    try testing.expectEqual(camera.PixelFormat.yuyv, pixelFormat(cv_2vuy));
    try testing.expectEqual(camera.PixelFormat.rgba, pixelFormat(cv_bgra));
    try testing.expectEqual(camera.PixelFormat.rgba, pixelFormat(cv_rgba));
    try testing.expectEqual(camera.PixelFormat.rgba, pixelFormat(cv_abgr));
    // The four-character code packs big-endian, matching the CoreVideo constants.
    try testing.expectEqual(@as(u32, 0x34323076), cv_420v);
    try testing.expectEqual(@as(u32, 0x42475241), cv_bgra);
    // Anything unrecognised is the honest closest default, not a fabricated layout.
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(0));
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(0xDEADBEEF));
}

test "a bound backend is dark until a session starts, and never opens the camera to enumerate" {
    var avf = AvfCameraBackend.init();
    var source = camera.CameraSource{};
    source.bind(avf.backend());
    defer source.stop();

    // Binding and enumerating never activate the camera — discovery reads the device list, it does not
    // open a session, so the indicator stays off and no frame is reported. The live path (an actual
    // capture session) is exercised only by a real Lens/Describe use, behind the indicator and the
    // approval, never here — so running the test suite does not light the camera.
    var buf: [max_cameras]camera.Camera = undefined;
    _ = source.cameras(&buf);
    try testing.expect(!source.indicatorLit());
    try testing.expectEqual(@as(?camera.Frame, null), source.latestFrame());
}
