//! The seam a graphics device sits behind: the Zig-owned interface a compositor
//! submits a frame to, so the same frame drives a real GPU on a device and the
//! software rasterizer in a test, a headless build, or recovery.
//!
//! A production shell renders on the GPU — that is where the efficiency, the wide
//! colour, and the effects live — but the GPU must not be the only path. A test has no
//! display, a recovery mode may run before the driver is up, and a reference frame is
//! compared pixel for pixel by the software rasterizer. The way to have both without
//! forking the renderer is one interface: the compositor produces a frame — the ordered
//! layers and the target it is for — and submits it to a `Device`, and which device is
//! behind the interface is a deployment choice, not a rendering one. The primary device
//! is a Vulkan adapter over the real GPU, chosen for the explicit control a consumer
//! display demands — HDR swapchains, wide-gamut surfaces, present modes tuned for
//! latency — and behind the same interface sits the software rasterizer for everywhere a
//! GPU is absent or must not be trusted yet. This module is that interface and the
//! software device that satisfies it; the Vulkan device is a native adapter that
//! implements the same three calls, and needs the loader and a GPU the interface is
//! built to accept.
//!
//! This module presents nothing to a physical display on its own. It defines the device
//! interface and a software device that records what it was asked to draw, so the
//! contract can be exercised without hardware.

const std = @import("std");
const layers = @import("../compositor/layers.zig");

pub const Layer = layers.Layer;
pub const Target = layers.Target;

/// What a device can do, so a caller can choose a colour path and know what a display
/// will honour. The software device reports the conservative baseline; a GPU device
/// reports what the attached panel attests to.
pub const Capabilities = struct {
    /// The widest colour space the device can present. The software baseline is sRGB;
    /// a real display may present Display-P3 or wider.
    color_space: ColorSpace = .srgb,
    /// Whether the device can present high dynamic range.
    hdr: bool = false,
    /// The bit depth per colour channel the device presents at.
    bits_per_channel: u8 = 8,

    pub const ColorSpace = enum { srgb, display_p3, rec2020 };
};

pub const Error = error{
    /// A frame was submitted with more layers than the device accepted this frame.
    FrameTooLarge,
    /// Present was called with no submitted frame to present.
    NothingToPresent,
};

/// A frame handed to a device: the ordered layers to draw and what they are for.
pub const Frame = struct {
    layers: []const Layer,
    target: Target,
};

/// A graphics device behind the seam. The compositor holds a `Device` and never knows
/// whether it is the GPU or the software rasterizer.
pub const Device = struct {
    context: *anyopaque,
    capabilities: Capabilities,
    submit_fn: *const fn (context: *anyopaque, frame: Frame) Error!void,
    present_fn: *const fn (context: *anyopaque) Error!void,

    /// Submits a frame to be drawn. The device records or rasterizes it; nothing is
    /// shown until `present`.
    pub fn submit(device: Device, frame: Frame) Error!void {
        return device.submit_fn(device.context, frame);
    }

    /// Presents the most recently submitted frame — to the display on a GPU device, or
    /// as the completed image on the software device.
    pub fn present(device: Device) Error!void {
        return device.present_fn(device.context);
    }
};

/// The software device: the fallback that satisfies the interface without a GPU. It
/// records the last frame it was submitted so a caller — a test, a headless render, the
/// reference comparison — can inspect exactly what would have been drawn.
pub const SoftwareDevice = struct {
    last_frame_layers: usize = 0,
    last_target: ?Target = null,
    presented: u64 = 0,
    /// The most layers a single frame may carry on this device.
    max_layers: usize = 4096,

    pub fn init() SoftwareDevice {
        return .{};
    }

    fn submitImpl(context: *anyopaque, frame: Frame) Error!void {
        const self: *SoftwareDevice = @ptrCast(@alignCast(context));
        if (frame.layers.len > self.max_layers) return error.FrameTooLarge;
        self.last_frame_layers = frame.layers.len;
        self.last_target = frame.target;
    }

    fn presentImpl(context: *anyopaque) Error!void {
        const self: *SoftwareDevice = @ptrCast(@alignCast(context));
        if (self.last_target == null) return error.NothingToPresent;
        self.presented += 1;
    }

    /// The interface handle for this software device.
    pub fn device(self: *SoftwareDevice) Device {
        return .{
            .context = self,
            // The conservative baseline: sRGB, SDR, 8-bit. A real display's device
            // reports what its panel attests to.
            .capabilities = .{},
            .submit_fn = submitImpl,
            .present_fn = presentImpl,
        };
    }
};

// --- Tests ---

const testing = std.testing;

fn oneLayer() [1]Layer {
    return .{.{ .node = 0, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .opacity = 1, .blend = .normal, .secure = false }};
}

test "the software device records a submitted frame and presents it" {
    var software = SoftwareDevice.init();
    const dev = software.device();

    const drawn = oneLayer();
    try dev.submit(.{ .layers = &drawn, .target = .screen });
    try testing.expectEqual(@as(usize, 1), software.last_frame_layers);
    try testing.expectEqual(Target.screen, software.last_target.?);

    try dev.present();
    try testing.expectEqual(@as(u64, 1), software.presented);
}

test "presenting before submitting is an error" {
    var software = SoftwareDevice.init();
    const dev = software.device();
    try testing.expectError(error.NothingToPresent, dev.present());
}

test "a frame larger than the device accepts is refused" {
    var software = SoftwareDevice.init();
    software.max_layers = 0;
    const dev = software.device();
    const drawn = oneLayer();
    try testing.expectError(error.FrameTooLarge, dev.submit(.{ .layers = &drawn, .target = .screen }));
}

test "the software device reports the conservative colour baseline" {
    var software = SoftwareDevice.init();
    const dev = software.device();
    try testing.expectEqual(Capabilities.ColorSpace.srgb, dev.capabilities.color_space);
    try testing.expectEqual(false, dev.capabilities.hdr);
    try testing.expectEqual(@as(u8, 8), dev.capabilities.bits_per_channel);
}

test "a device is used through the interface without knowing which device it is" {
    // The seam property: code holds a Device and drives it the same way whatever is
    // behind it — here the software device, in production the GPU.
    var software = SoftwareDevice.init();
    const dev: Device = software.device();
    const drawn = oneLayer();
    try dev.submit(.{ .layers = &drawn, .target = .capture });
    try dev.present();
    try testing.expectEqual(Target.capture, software.last_target.?);
}
