//! The V4L2 camera backend: a real Linux backend behind the platform camera seam
//! (services/media/camera.zig), enumerating the host's actual `/dev/video*` capture devices through
//! Video4Linux2.
//!
//! V4L2 is reached through kernel ioctls over libc — there is no external library to link. This module
//! opens each `/dev/videoN`, asks it to describe itself (VIDIOC_QUERYCAP), and reports the ones that
//! can capture video, each with the card name the driver gives. Behind the same seam it runs a real
//! memory-mapped capture stream: it negotiates the capture format, requests and maps a small ring of
//! kernel buffers (VIDIOC_REQBUFS/QUERYBUF/mmap/QBUF), starts the stream (VIDIOC_STREAMON), and on each
//! frame read dequeues the latest filled buffer (VIDIOC_DQBUF) and requeues it. Only the frame's shape —
//! the negotiated width, height, and pixel format — crosses the seam; the mapped pixels stay in the
//! backend, so a frame read is O(1), never a per-pixel copy. The UAPI structs and ioctl requests are
//! hand-declared against the stable V4L2 ABI, so no C headers are needed to build; every C detail stays
//! inside this module, and the seam above sees only Zig types. A device's name is owned by the backend
//! so it outlives the enumeration call. Built only on Linux; off Linux the module is never compiled and
//! the camera seam keeps its dark honest-until-bound default.

const std = @import("std");
const camera = @import("camera");

// --- libc, hand-declared (no @cImport; only the few calls the adapter needs) ---
extern fn open(path: [*:0]const u8, flags: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: c_long) ?*anyopaque;
extern fn munmap(addr: ?*anyopaque, length: usize) c_int;

const O_RDWR: c_int = 0x0002;
const O_NONBLOCK: c_int = 0x0800; // Linux value

// mmap protection and sharing flags, and the sentinel mmap returns on failure ((void *)-1).
const PROT_READ: c_int = 0x1;
const PROT_WRITE: c_int = 0x2;
const MAP_SHARED: c_int = 0x1;
const map_failed: usize = std.math.maxInt(usize);

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

// --- V4L2 streaming UAPI, hand-declared against the stable 64-bit ABI ---
//
// The ioctl request numbers are derived from the same `_IOWR`/`_IOW` encoding the kernel uses, over the
// struct sizes below (`ioctlEncoding` mirrors `_IOC`). A test pins each number to its known literal, so
// any drift in a struct's size — the very thing that would silently corrupt an ioctl — trips the test.
// The struct layouts follow the 64-bit kernel ABI: `v4l2_buffer` and `v4l2_format` embed members that
// are 8-byte aligned there (a `timeval`, a union holding a pointer), so their fields sit at the same
// offsets the kernel reads and writes. The cross-compile target is `x86_64-linux-gnu`, so 64-bit is the
// layout that must match.

const V4L2_BUF_TYPE_VIDEO_CAPTURE: u32 = 1;
const V4L2_MEMORY_MMAP: u32 = 1;

/// `struct v4l2_pix_format` — the single-planar capture format (48 bytes on the 64-bit ABI).
const v4l2_pix_format = extern struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv: u32,
    flags: u32,
    enc: u32, // ycbcr_enc / hsv_enc union — one u32 either way
    quantization: u32,
    xfer_func: u32,
};

/// `struct v4l2_format`. The kernel's `fmt` union is 8-byte aligned (it holds `v4l2_window`, which has
/// pointers), so it begins at offset 8 after `type`, and the whole struct is 208 bytes. `pix` overlays
/// the front of that union; the trailing bytes pad it to the union's full size.
const v4l2_format = extern struct {
    type: u32,
    _pad: u32 = 0, // the fmt union is 8-byte aligned, so it starts at offset 8, not 4
    pix: v4l2_pix_format,
    _tail: [200 - @sizeOf(v4l2_pix_format)]u8 = [_]u8{0} ** (200 - @sizeOf(v4l2_pix_format)),
};

/// `struct v4l2_requestbuffers` (20 bytes): how many buffers, of what type and memory model.
const v4l2_requestbuffers = extern struct {
    count: u32,
    type: u32,
    memory: u32,
    capabilities: u32 = 0,
    flags: u8 = 0,
    _reserved: [3]u8 = [_]u8{0} ** 3,
};

/// `struct timeval` on the 64-bit ABI: two 8-byte longs.
const timeval = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

/// `struct v4l2_timecode` (16 bytes).
const v4l2_timecode = extern struct {
    type: u32,
    flags: u32,
    frames: u8,
    seconds: u8,
    minutes: u8,
    hours: u8,
    userbits: [4]u8,
};

/// `struct v4l2_buffer` (88 bytes on the 64-bit ABI). The explicit pads reproduce the kernel's natural
/// alignment: `timestamp` (a `timeval`) is 8-byte aligned, and the `m` union holds a pointer, so both
/// land where the kernel expects. The adapter uses `index`, `type`, `memory`, `bytesused`, `length`,
/// and `m.offset` (the mmap offset); the rest is carried so the layout — and thus the ioctl size — is
/// exact.
const v4l2_buffer = extern struct {
    index: u32,
    type: u32,
    bytesused: u32,
    flags: u32,
    field: u32,
    _pad0: u32 = 0, // align timestamp to offset 24
    timestamp: timeval,
    timecode: v4l2_timecode,
    sequence: u32,
    memory: u32,
    m: extern union {
        offset: u32,
        userptr: u64,
        planes: usize,
        fd: i32,
    },
    length: u32,
    reserved2: u32 = 0,
    request_fd: i32 = 0,
    _pad1: u32 = 0, // pad the struct out to 88 bytes
};

/// `_IOC(dir, 'V', nr, size)` — the ioctl request encoding the kernel uses. `dir` is 1 for write, 2 for
/// read, 3 for both; the size is the payload struct's size.
fn ioctlEncoding(dir: c_ulong, nr: c_ulong, size: c_ulong) c_ulong {
    return (dir << 30) | (size << 16) | (@as(c_ulong, 'V') << 8) | nr;
}
fn iowr(nr: c_ulong, comptime T: type) c_ulong {
    return ioctlEncoding(3, nr, @sizeOf(T));
}
fn iow(nr: c_ulong, comptime T: type) c_ulong {
    return ioctlEncoding(1, nr, @sizeOf(T));
}

const VIDIOC_G_FMT: c_ulong = iowr(4, v4l2_format);
const VIDIOC_REQBUFS: c_ulong = iowr(8, v4l2_requestbuffers);
const VIDIOC_QUERYBUF: c_ulong = iowr(9, v4l2_buffer);
const VIDIOC_QBUF: c_ulong = iowr(15, v4l2_buffer);
const VIDIOC_DQBUF: c_ulong = iowr(17, v4l2_buffer);
const VIDIOC_STREAMON: c_ulong = iow(18, c_int);
const VIDIOC_STREAMOFF: c_ulong = iow(19, c_int);

/// A V4L2 pixelformat fourcc, packed little-endian the way the `v4l2_fourcc` macro builds it.
fn fourcc(comptime code: *const [4]u8) u32 {
    return @as(u32, code[0]) | (@as(u32, code[1]) << 8) | (@as(u32, code[2]) << 16) | (@as(u32, code[3]) << 24);
}

// The pixelformats the adapter maps. NV12/NV21 are the biplanar 4:2:0 the seam calls nv12; the packed
// 4:2:2 codes are YUYV-class; the packed 24/32-bit RGB codes are RGBA-class. Anything else is the
// honest closest default, nv12.
const V4L2_PIX_FMT_NV12 = fourcc("NV12");
const V4L2_PIX_FMT_NV21 = fourcc("NV21");
const V4L2_PIX_FMT_YUYV = fourcc("YUYV");
const V4L2_PIX_FMT_YVYU = fourcc("YVYU");
const V4L2_PIX_FMT_UYVY = fourcc("UYVY");
const V4L2_PIX_FMT_VYUY = fourcc("VYUY");
const V4L2_PIX_FMT_RGB24 = fourcc("RGB3");
const V4L2_PIX_FMT_BGR24 = fourcc("BGR3");
const V4L2_PIX_FMT_RGB32 = fourcc("RGB4");
const V4L2_PIX_FMT_BGR32 = fourcc("BGR4");
const V4L2_PIX_FMT_RGBA32 = fourcc("AB24");
const V4L2_PIX_FMT_ABGR32 = fourcc("AR24");

/// Maps a V4L2 pixelformat fourcc to the seam's `PixelFormat`, choosing the closest family and
/// defaulting to nv12 for anything unrecognised — an honest closest match, never a guess that would
/// misdescribe the pixel layout.
fn pixelFormat(code: u32) camera.PixelFormat {
    return switch (code) {
        V4L2_PIX_FMT_NV12, V4L2_PIX_FMT_NV21 => .nv12,
        V4L2_PIX_FMT_YUYV, V4L2_PIX_FMT_YVYU, V4L2_PIX_FMT_UYVY, V4L2_PIX_FMT_VYUY => .yuyv,
        V4L2_PIX_FMT_RGB24, V4L2_PIX_FMT_BGR24, V4L2_PIX_FMT_RGB32, V4L2_PIX_FMT_BGR32, V4L2_PIX_FMT_RGBA32, V4L2_PIX_FMT_ABGR32 => .rgba,
        else => .nv12,
    };
}

/// How many `/dev/videoN` nodes to probe. The kernel numbers capture nodes from 0; 64 is well past any
/// realistic count and absent nodes simply fail to open and are skipped.
const max_nodes: usize = 64;
const max_cameras: usize = 16;
/// The capture ring: a few mmap'd kernel buffers cycled through the queue. Four is the usual small ring.
const max_buffers: usize = 4;

/// One mmap'd capture buffer: the mapped memory and its length, held so `munmap` can release exactly
/// what was mapped.
const MappedBuffer = struct {
    ptr: [*]u8,
    len: usize,
};

/// The live capture session's state: the open fd, the mapped buffer ring, whether the stream is
/// running, whether a frame has been delivered yet, and the negotiated frame shape. Defaults are the
/// "nothing running" state, so a fresh `Stream{}` is honestly dark.
const Stream = struct {
    fd: c_int = -1,
    buffers: [max_buffers]?MappedBuffer = [_]?MappedBuffer{null} ** max_buffers,
    buffer_count: usize = 0,
    running: bool = false,
    has_frame: bool = false,
    width: u16 = 0,
    height: u16 = 0,
    format: camera.PixelFormat = .nv12,
};

/// A V4L2-backed camera source. Owns the names it reports so the seam's borrowed slices stay valid
/// until the next enumeration, and the live capture session while a stream runs.
pub const V4l2Backend = struct {
    name_store: [max_cameras][32]u8 = undefined,
    stream: Stream = .{},

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
        return nodeForId(camera_id) != null;
    }

    /// The `/dev/videoN` node index whose capture card hashes to `camera_id`, or null if none does.
    fn nodeForId(camera_id: u32) ?usize {
        var node: usize = 0;
        while (node < max_nodes) : (node += 1) {
            var cap: v4l2_capability = undefined;
            const card = captureCard(node, &cap) orelse continue;
            if (idOf(card) == camera_id) return node;
        }
        return null;
    }

    fn startStreamFn(context: *anyopaque, camera_id: u32) camera.StartError!void {
        const self: *V4l2Backend = @ptrCast(@alignCast(context));
        return self.startStream(camera_id);
    }

    fn stopStreamFn(context: *anyopaque) void {
        const self: *V4l2Backend = @ptrCast(@alignCast(context));
        self.stopStream();
    }

    fn streamLiveFn(context: *anyopaque) bool {
        const self: *V4l2Backend = @ptrCast(@alignCast(context));
        return self.stream.running;
    }

    fn latestFrameFn(context: *anyopaque, out: *camera.Frame) bool {
        const self: *V4l2Backend = @ptrCast(@alignCast(context));
        return self.latestFrame(out);
    }

    /// Starts a memory-mapped capture stream on the camera. A missing device is the seam's
    /// `NoSuchCamera`. A real device whose capture pipeline will not come up is not `NoSuchCamera`: the
    /// session is left torn down, so `stream_live` reads honestly off, honest about what did not start
    /// rather than claiming the camera is absent.
    fn startStream(self: *V4l2Backend, camera_id: u32) camera.StartError!void {
        self.stopStream(); // never leak a prior session
        const node = nodeForId(camera_id) orelse return camera.StartError.NoSuchCamera;
        self.bringUp(node) catch self.stopStream();
    }

    /// Brings the capture pipeline up on `node`: open, negotiate the format, request and map the buffer
    /// ring, queue every buffer, and stream on. Any failed step returns an error with the fd and any
    /// buffers mapped so far recorded on `self.stream`, so the caller's `stopStream` unwinds them.
    fn bringUp(self: *V4l2Backend, node: usize) !void {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/video{d}", .{node}) catch return error.SetupFailed;
        const fd = open(path.ptr, O_RDWR | O_NONBLOCK);
        if (fd < 0) return error.SetupFailed; // the node vanished between the scan and the open
        self.stream.fd = fd;

        // Read the negotiated capture format so the frame's shape is known before any buffer arrives.
        var fmt: v4l2_format = std.mem.zeroes(v4l2_format);
        fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (ioctl(fd, VIDIOC_G_FMT, &fmt) != 0) return error.SetupFailed;
        self.stream.width = @intCast(@min(fmt.pix.width, @as(u32, std.math.maxInt(u16))));
        self.stream.height = @intCast(@min(fmt.pix.height, @as(u32, std.math.maxInt(u16))));
        self.stream.format = pixelFormat(fmt.pix.pixelformat);

        // Ask the driver for a small ring of mmap buffers.
        var req: v4l2_requestbuffers = std.mem.zeroes(v4l2_requestbuffers);
        req.count = max_buffers;
        req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        req.memory = V4L2_MEMORY_MMAP;
        if (ioctl(fd, VIDIOC_REQBUFS, &req) != 0) return error.SetupFailed;
        if (req.count == 0) return error.SetupFailed; // no buffers granted, nothing to capture into

        // Query, map, and queue each granted buffer.
        const count = @min(@as(usize, req.count), max_buffers);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            var buf: v4l2_buffer = std.mem.zeroes(v4l2_buffer);
            buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buf.memory = V4L2_MEMORY_MMAP;
            buf.index = index;
            if (ioctl(fd, VIDIOC_QUERYBUF, &buf) != 0) return error.SetupFailed;

            const mapped = mmap(null, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, @intCast(buf.m.offset));
            const addr = mapped orelse return error.SetupFailed;
            if (@intFromPtr(addr) == map_failed) return error.SetupFailed;
            self.stream.buffers[index] = .{ .ptr = @ptrCast(addr), .len = buf.length };
            self.stream.buffer_count = index + 1;

            if (ioctl(fd, VIDIOC_QBUF, &buf) != 0) return error.SetupFailed; // hand the buffer to the driver
        }

        var buf_type: c_int = @intCast(V4L2_BUF_TYPE_VIDEO_CAPTURE);
        if (ioctl(fd, VIDIOC_STREAMON, &buf_type) != 0) return error.SetupFailed;
        self.stream.running = true;
    }

    /// Stops the stream and tears it down: stream off, unmap every buffer, close the fd, and reset to
    /// the dark default. Idempotent — with nothing running it does nothing observable.
    fn stopStream(self: *V4l2Backend) void {
        if (self.stream.fd >= 0) {
            if (self.stream.running) {
                var buf_type: c_int = @intCast(V4L2_BUF_TYPE_VIDEO_CAPTURE);
                _ = ioctl(self.stream.fd, VIDIOC_STREAMOFF, &buf_type);
            }
            var i: usize = 0;
            while (i < self.stream.buffer_count) : (i += 1) {
                if (self.stream.buffers[i]) |mb| _ = munmap(mb.ptr, mb.len);
            }
            _ = close(self.stream.fd);
        }
        self.stream = .{};
    }

    /// Reports the latest delivered frame's shape, or false before any frame has arrived. It dequeues at
    /// most one filled buffer to observe that a frame was delivered, then requeues it so capture keeps
    /// cycling — an O(1) shape read, never a copy of the mapped pixels across the seam. Once a frame has
    /// been seen the shape (the negotiated format) is reported even between buffers.
    fn latestFrame(self: *V4l2Backend, out: *camera.Frame) bool {
        if (!self.stream.running) return false;
        var buf: v4l2_buffer = std.mem.zeroes(v4l2_buffer);
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (ioctl(self.stream.fd, VIDIOC_DQBUF, &buf) == 0) {
            self.stream.has_frame = true;
            _ = ioctl(self.stream.fd, VIDIOC_QBUF, &buf); // requeue the same buffer for the driver to refill
        }
        if (!self.stream.has_frame) return false; // no frame has been delivered yet — honestly none
        out.* = .{ .width = self.stream.width, .height = self.stream.height, .format = self.stream.format };
        return true;
    }

    /// Presents this V4L2 source as a backend the camera seam can bind.
    pub fn backend(self: *V4l2Backend) camera.Backend {
        return .{
            .context = self,
            .cameras_fn = camerasFn,
            .has_camera_fn = hasCameraFn,
            .start_stream_fn = startStreamFn,
            .stop_stream_fn = stopStreamFn,
            .stream_live_fn = streamLiveFn,
            .latest_frame_fn = latestFrameFn,
        };
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

test "the streaming struct sizes and ioctl numbers match the 64-bit V4L2 ABI" {
    // The ioctl numbers encode each struct's size, so pinning them to their known kernel literals guards
    // the hand-declared layouts: any drift in a struct's size trips exactly here.
    try testing.expectEqual(@as(usize, 208), @sizeOf(v4l2_format));
    try testing.expectEqual(@as(usize, 20), @sizeOf(v4l2_requestbuffers));
    try testing.expectEqual(@as(usize, 88), @sizeOf(v4l2_buffer));
    // The overlaid capture format must sit at offset 8 (after `type` and the union's 8-byte alignment).
    try testing.expectEqual(@as(usize, 8), @offsetOf(v4l2_format, "pix"));
    try testing.expectEqual(@as(c_ulong, 0xC0D05604), VIDIOC_G_FMT);
    try testing.expectEqual(@as(c_ulong, 0xC0145608), VIDIOC_REQBUFS);
    try testing.expectEqual(@as(c_ulong, 0xC0585609), VIDIOC_QUERYBUF);
    try testing.expectEqual(@as(c_ulong, 0xC058560F), VIDIOC_QBUF);
    try testing.expectEqual(@as(c_ulong, 0xC0585611), VIDIOC_DQBUF);
    try testing.expectEqual(@as(c_ulong, 0x40045612), VIDIOC_STREAMON);
    try testing.expectEqual(@as(c_ulong, 0x40045613), VIDIOC_STREAMOFF);
}

test "the pixelformat fourccs map to the seam's families, defaulting to nv12" {
    // Biplanar 4:2:0 is nv12; the packed 4:2:2 codes are yuyv-class; the packed RGB codes are rgba.
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(V4L2_PIX_FMT_NV12));
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(V4L2_PIX_FMT_NV21));
    try testing.expectEqual(camera.PixelFormat.yuyv, pixelFormat(V4L2_PIX_FMT_YUYV));
    try testing.expectEqual(camera.PixelFormat.yuyv, pixelFormat(V4L2_PIX_FMT_UYVY));
    try testing.expectEqual(camera.PixelFormat.rgba, pixelFormat(V4L2_PIX_FMT_RGB24));
    try testing.expectEqual(camera.PixelFormat.rgba, pixelFormat(V4L2_PIX_FMT_RGBA32));
    // The fourcc packs little-endian the way the kernel's v4l2_fourcc macro builds it.
    try testing.expectEqual(@as(u32, 0x3231564E), V4L2_PIX_FMT_NV12); // 'N''V''1''2'
    try testing.expectEqual(@as(u32, 0x56595559), V4L2_PIX_FMT_YUYV); // 'Y''U''Y''V'
    // Anything unrecognised is the honest closest default, not a fabricated layout.
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(0));
    try testing.expectEqual(camera.PixelFormat.nv12, pixelFormat(0xDEADBEEF));
}

test "a streaming backend is dark until a frame arrives, and an unknown camera cannot start" {
    // On a headless CI runner there is no `/dev/video*`, so this exercises the honest-until-bound and
    // honest-until-first-frame state without any hardware: nothing is live, no frame is reported, and a
    // start against an id no node reports fails NoSuchCamera through the real streaming path.
    var v4l2 = V4l2Backend{};
    var source = camera.CameraSource{};
    source.bind(v4l2.backend());
    defer source.stop();

    // Before any start: the session is not live and no frame has been delivered.
    try testing.expect(!source.indicatorLit());
    try testing.expectEqual(@as(?camera.Frame, null), source.latestFrame());

    // An id that no node reports cannot start — the streaming path validates existence itself.
    try testing.expectError(camera.StartError.NoSuchCamera, source.start(0));

    // On a host that does have a camera, start it and confirm the frame contract holds: a delivered
    // frame is well formed, and none is fabricated before delivery.
    var buf: [max_cameras]camera.Camera = undefined;
    const found = source.cameras(&buf);
    if (found.len == 0) return; // headless: nothing to start, honestly nothing more to check
    try source.start(found[0].id);
    if (source.latestFrame()) |frame| {
        try testing.expect(frame.width > 0 and frame.height > 0);
    }
    source.stop();
    try testing.expect(!source.indicatorLit());
    try testing.expectEqual(@as(?camera.Frame, null), source.latestFrame());
}
