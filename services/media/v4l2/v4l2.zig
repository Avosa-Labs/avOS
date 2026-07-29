//! The V4L2 camera backend: a real Linux backend behind the platform camera seam
//! (services/media/camera.zig), enumerating the host's actual `/dev/video*` capture devices through
//! Video4Linux2.
//!
//! V4L2 is reached through kernel ioctls over libc — there is no external library to link. This module
//! opens each `/dev/videoN`, asks it to describe itself (VIDIOC_QUERYCAP), and reports the ones that
//! can capture video, each with the card name the driver gives. The UAPI struct and ioctl request are
//! hand-declared against the stable V4L2 ABI, so no C headers are needed to build; every C detail stays
//! inside this module, and the seam above sees only Zig types. A device's name is owned by the backend
//! so it outlives the enumeration call. Built only on Linux; off Linux the module is never compiled and
//! the camera seam keeps its dark honest-until-bound default.

const std = @import("std");
const camera = @import("camera");

// --- libc, hand-declared (no @cImport; only the few calls the enumeration needs) ---
extern fn open(path: [*:0]const u8, flags: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const O_RDWR: c_int = 0x0002;
const O_NONBLOCK: c_int = 0x0800; // Linux value

// --- V4L2 UAPI, hand-declared against the stable ABI ---

/// `struct v4l2_capability` — the layout the VIDIOC_QUERYCAP ioctl fills in. Exactly 104 bytes; the
/// field order and widths are load-bearing (the kernel writes this by offset).
const v4l2_capability = extern struct {
    driver: [16]u8,
    card: [32]u8,
    bus_info: [32]u8,
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [3]u32,
};

/// VIDIOC_QUERYCAP = _IOR('V', 0, struct v4l2_capability):
///   direction _IOC_READ (2) << 30 | sizeof(=104) << 16 | 'V'(0x56) << 8 | nr(0)
///   = 0x8000_0000 | 0x0068_0000 | 0x0000_5600 = 0x8068_5600
const VIDIOC_QUERYCAP: c_ulong = 0x80685600;

const V4L2_CAP_VIDEO_CAPTURE: u32 = 0x00000001;
/// When set, the per-device `device_caps` is the authoritative capability set for this node.
const V4L2_CAP_DEVICE_CAPS: u32 = 0x80000000;

/// How many `/dev/videoN` nodes to probe. The kernel numbers capture nodes from 0; 64 is well past any
/// realistic count and absent nodes simply fail to open and are skipped.
const max_nodes: usize = 64;
const max_cameras: usize = 16;

/// A V4L2-backed camera source. Owns the names it reports so the seam's borrowed slices stay valid
/// until the next enumeration.
pub const V4l2Backend = struct {
    name_store: [max_cameras][32]u8 = undefined,

    fn nameAt(store: *V4l2Backend, index: usize, card: []const u8) []const u8 {
        const n = @min(card.len, store.name_store[index].len);
        @memcpy(store.name_store[index][0..n], card[0..n]);
        return store.name_store[index][0..n];
    }

    /// A stable id for a camera from its card name, so the same device keeps its id across a
    /// re-enumeration. Zero is reserved so it can never collide with "no device".
    fn idOf(card: []const u8) u32 {
        var hash: u32 = 2166136261;
        for (card) |byte| hash = (hash ^ byte) *% 16777619;
        return if (hash == 0) 1 else hash;
    }

    /// The card name a node reports if it can capture video, or null if the node is absent, cannot be
    /// queried, or is not a capture device. Trims the fixed `card` buffer at its NUL.
    fn captureCard(node: usize, cap: *v4l2_capability) ?[]const u8 {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/video{d}", .{node}) catch return null;
        const fd = open(path.ptr, O_RDWR | O_NONBLOCK);
        if (fd < 0) return null;
        defer _ = close(fd);
        if (ioctl(fd, VIDIOC_QUERYCAP, cap) != 0) return null;
        // When a node advertises per-device caps, those govern this node; otherwise the physical
        // device's overall caps do.
        const node_caps = if (cap.capabilities & V4L2_CAP_DEVICE_CAPS != 0) cap.device_caps else cap.capabilities;
        if (node_caps & V4L2_CAP_VIDEO_CAPTURE == 0) return null;
        const nul = std.mem.indexOfScalar(u8, &cap.card, 0) orelse cap.card.len;
        return cap.card[0..nul];
    }

    fn camerasFn(context: *anyopaque, out: []camera.Camera) []const camera.Camera {
        const self: *V4l2Backend = @ptrCast(@alignCast(context));
        var n: usize = 0;
        var node: usize = 0;
        while (node < max_nodes and n < out.len and n < max_cameras) : (node += 1) {
            var cap: v4l2_capability = undefined;
            const card = captureCard(node, &cap) orelse continue;
            out[n] = .{ .id = idOf(card), .name = self.nameAt(n, card) };
            n += 1;
        }
        return out[0..n];
    }

    fn hasCameraFn(context: *anyopaque, camera_id: u32) bool {
        _ = context;
        var node: usize = 0;
        while (node < max_nodes) : (node += 1) {
            var cap: v4l2_capability = undefined;
            const card = captureCard(node, &cap) orelse continue;
            if (idOf(card) == camera_id) return true;
        }
        return false;
    }

    /// Presents this V4L2 source as a backend the camera seam can bind.
    pub fn backend(self: *V4l2Backend) camera.Backend {
        return .{ .context = self, .cameras_fn = camerasFn, .has_camera_fn = hasCameraFn };
    }
};

// --- Tests ---
//
// A CI Linux runner is headless and has no `/dev/video*`, so enumeration correctly returns zero
// cameras. These assert the honest behaviour (no crash, a well-formed slice, has-camera agrees with
// what enumeration reports) without depending on any hardware being present.

const testing = std.testing;

test "enumeration is well-formed whether or not the host has cameras" {
    var v4l2 = V4l2Backend{};
    var source = camera.CameraSource{};
    source.bind(v4l2.backend());

    var buf: [max_cameras]camera.Camera = undefined;
    const found = source.cameras(&buf);
    // Zero on a headless host is correct; any camera reported must carry a non-empty name.
    for (found) |cam| {
        try testing.expect(cam.name.len > 0);
        try testing.expect(cam.id != 0);
    }
}

test "has-camera agrees with what enumeration reports" {
    var v4l2 = V4l2Backend{};
    var source = camera.CameraSource{};
    source.bind(v4l2.backend());

    var buf: [max_cameras]camera.Camera = undefined;
    const found = source.cameras(&buf);
    const b = v4l2.backend();
    for (found) |cam| {
        try testing.expect(b.has_camera_fn(b.context, cam.id));
    }
    // An id that no device reports is not present.
    try testing.expect(!b.has_camera_fn(b.context, 0));
}

test "the ioctl request number is the V4L2 QUERYCAP encoding" {
    // Guards the hand-derived constant against a typo: _IOR('V', 0, [104]u8).
    try testing.expectEqual(@as(c_ulong, 0x80685600), VIDIOC_QUERYCAP);
    try testing.expectEqual(@as(usize, 104), @sizeOf(v4l2_capability));
}
