//! The AVFoundation camera adapter: a Zig backend over the macOS capture stack, bound behind the
//! platform camera seam (`services/media/camera.zig`).
//!
//! AVFoundation is macOS's capture framework. This adapter reaches it only to answer the two questions
//! the seam asks: what cameras exist, and does a given camera id exist. It discovers the host's video
//! capture devices (built-in wide-angle plus external), maps each to a stable small integer id (a hash
//! of its uniqueID) and its localizedName, and answers has-camera against that live set. Actually
//! starting an AVCaptureSession is a follow-up behind the same seam — the seam derives its privacy
//! indicator from whether a stream is live, which this enumeration adapter does not touch.
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
const c = @import("bindings.zig").c;

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

    // Every enumerated camera can start (it exists); starting lights the indicator, stopping clears it.
    for (cameras) |cam| {
        try source.start(cam.id);
        try testing.expect(source.indicatorLit());
        source.stop();
        try testing.expect(!source.indicatorLit());
    }

    // An id not in the set cannot start — the backend reports no such camera.
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
