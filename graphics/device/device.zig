//! The seam a graphics device sits behind: the Zig-owned interface a compositor
//! submits a frame to, so the same frame drives a real GPU on a device and the
//! software rasterizer in a test, a headless build, or recovery.
//!
//! A production shell renders on the GPU — that is where the efficiency, the wide
//! colour, and the effects live — but the GPU must not be the only path. A test has no
//! display, a recovery mode may run before the driver is up, and a reference frame is
//! compared pixel for pixel by the software rasterizer. The way to have both without
//! forking the renderer is one interface: the compositor produces a frame — the retained
//! scene and the target it is for — and submits it to a `Device`, and which device is
//! behind the interface is a deployment choice, not a rendering one. The primary device
//! is a Vulkan adapter over the real GPU, chosen for the explicit control a consumer
//! display demands — HDR swapchains, wide-gamut surfaces, present modes tuned for
//! latency — and behind the same interface sits the software rasterizer for everywhere a
//! GPU is absent or must not be trusted yet. This module is that interface and the
//! software device that satisfies it; the Vulkan device is a native adapter that
//! implements the same three calls, and needs the loader and a GPU the interface is
//! built to accept.
//!
//! A frame carries the scene, not a pre-drawn image: the retained tree and its per-node
//! display lists, so each device draws them its own way — the software device composites
//! them into a framebuffer it owns, a GPU device batches them into a pass. This module
//! presents nothing to a physical display on its own; it defines the interface and the
//! software device that produces the completed image, so the contract can be exercised
//! and compared pixel for pixel without hardware.

const std = @import("std");
const layers = @import("../compositor/layers.zig");
const raster = @import("../compositor/raster.zig");
const framebuffer = @import("../paint/framebuffer.zig");
const tree_mod = @import("../scene/tree.zig");

pub const Layer = layers.Layer;
pub const Target = layers.Target;
pub const Tree = tree_mod.Tree;
pub const Framebuffer = framebuffer.Framebuffer;
pub const Rgba = framebuffer.Rgba;

/// A node's drawable content: the paint commands for that node, authored in its own local
/// space. `Frame.lists[i]` is node `i`'s list — the same slice `raster.composite` consumes.
pub const DisplayList = raster.DisplayList;

/// The render-path policy: which device draws a frame (GPU primary, software fallback) and
/// why. The compositor consults this to choose a device rather than defaulting to software.
pub const path = @import("path.zig");

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
    /// A frame's scene has more nodes than the device's flatten buffer can hold.
    FrameTooLarge,
    /// Present was called with no submitted frame to present.
    NothingToPresent,
    /// The device could not allocate the memory to compose the frame.
    OutOfMemory,
    /// The device failed to draw the frame — a GPU call failed or no suitable memory
    /// was available. The software device never returns this; a GPU device may.
    RenderFailed,
};

/// A frame handed to a device: the retained scene to draw — the tree and its per-node
/// display lists — and what the frame is for. The device turns this into pixels; the seam
/// carries no pre-drawn image, so the same frame drives a GPU pass or a software raster.
pub const Frame = struct {
    tree: Tree,
    lists: []const DisplayList,
    target: Target,
};

/// A graphics device behind the seam. The compositor holds a `Device` and never knows
/// whether it is the GPU or the software rasterizer.
pub const Device = struct {
    context: *anyopaque,
    capabilities: Capabilities,
    submit_fn: *const fn (context: *anyopaque, frame: Frame) Error!void,
    present_fn: *const fn (context: *anyopaque) Error!void,

    /// Submits a frame to be drawn. The device composes or records it; nothing is shown
    /// until `present`.
    pub fn submit(device: Device, frame: Frame) Error!void {
        return device.submit_fn(device.context, frame);
    }

    /// Presents the most recently submitted frame — to the display on a GPU device, or
    /// as the completed image on the software device.
    pub fn present(device: Device) Error!void {
        return device.present_fn(device.context);
    }
};

/// The software device: the fallback that satisfies the interface without a GPU. It owns a
/// framebuffer the size of the display, composites each submitted frame's scene into it
/// with the software rasterizer, and keeps it as the completed image so a caller — a test,
/// a headless render, the reference comparison — can read exactly what would be shown.
pub const SoftwareDevice = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    /// The colour a frame is cleared to before its scene is composited over it.
    background: Rgba,
    /// The device's own flatten buffer; a frame whose scene needs more layers is refused.
    layer_buffer: []Layer,
    /// The most recently composited frame, owned by this device.
    image: ?Framebuffer = null,
    presented: u64 = 0,
    last_target: ?Target = null,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, background: Rgba, layer_buffer: []Layer) SoftwareDevice {
        return .{ .gpa = gpa, .width = width, .height = height, .background = background, .layer_buffer = layer_buffer };
    }

    pub fn deinit(self: *SoftwareDevice) void {
        if (self.image) |*image| image.deinit();
        self.image = null;
    }

    fn submitImpl(context: *anyopaque, frame: Frame) Error!void {
        const self: *SoftwareDevice = @ptrCast(@alignCast(context));
        // The flatten buffer bounds how many layers a frame may carry; nodes are an upper
        // bound on visible layers, so a scene with more nodes than the buffer is refused
        // rather than silently truncated.
        if (frame.tree.nodes.len > self.layer_buffer.len) return error.FrameTooLarge;

        var image = Framebuffer.init(self.gpa, self.width, self.height, self.background) catch return error.OutOfMemory;
        errdefer image.deinit();
        raster.composite(self.gpa, &image, frame.tree, frame.lists, self.layer_buffer, frame.target) catch return error.OutOfMemory;

        if (self.image) |*old| old.deinit(); // release the previous frame before keeping this one
        self.image = image;
        self.last_target = frame.target;
    }

    fn presentImpl(context: *anyopaque) Error!void {
        const self: *SoftwareDevice = @ptrCast(@alignCast(context));
        if (self.image == null) return error.NothingToPresent;
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
const paint = @import("../paint/paint.zig");
const Node = tree_mod.Node;

fn solidList(rect: paint.Rect, colour: Rgba) [1]paint.Command {
    return .{.{ .solid = .{ .rect = rect, .colour = colour } }};
}

test "the software device composites a submitted scene into its image and presents it" {
    // A red background node, and a blue node translated to (20,20).
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
        .{ .parent = 0, .transform = tree_mod.Transform.translate(20, 20), .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const bg = solidList(.{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const fg = solidList(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 0, .g = 0, .b = 200, .a = 255 });
    const lists = [_]DisplayList{ &bg, &fg };

    var layer_buf: [8]Layer = undefined;
    var software = SoftwareDevice.init(testing.allocator, 40, 40, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, &layer_buf);
    defer software.deinit();
    const dev = software.device();

    try dev.submit(.{ .tree = tree, .lists = &lists, .target = .screen });
    try testing.expectEqual(Target.screen, software.last_target.?);

    const image = software.image.?;
    try testing.expectEqual(@as(u8, 200), image.get(5, 5).r); // background red where uncovered
    try testing.expectEqual(@as(u8, 200), image.get(25, 25).b); // blue node at its world offset
    try testing.expectEqual(@as(u8, 0), image.get(25, 25).r); // and it is over the red

    try dev.present();
    try testing.expectEqual(@as(u64, 1), software.presented);
}

test "presenting before submitting is an error" {
    var layer_buf: [4]Layer = undefined;
    var software = SoftwareDevice.init(testing.allocator, 8, 8, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, &layer_buf);
    defer software.deinit();
    try testing.expectError(error.NothingToPresent, software.device().present());
}

test "a scene with more nodes than the flatten buffer is refused" {
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 8 } },
        .{ .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 8 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const empty = [_]paint.Command{};
    const lists = [_]DisplayList{ &empty, &empty };

    var layer_buf: [1]Layer = undefined; // room for one, the scene has two nodes
    var software = SoftwareDevice.init(testing.allocator, 8, 8, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, &layer_buf);
    defer software.deinit();
    try testing.expectError(error.FrameTooLarge, software.device().submit(.{ .tree = tree, .lists = &lists, .target = .screen }));
}

test "the software device reports the conservative colour baseline" {
    var layer_buf: [4]Layer = undefined;
    var software = SoftwareDevice.init(testing.allocator, 8, 8, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, &layer_buf);
    defer software.deinit();
    const dev = software.device();
    try testing.expectEqual(Capabilities.ColorSpace.srgb, dev.capabilities.color_space);
    try testing.expectEqual(false, dev.capabilities.hdr);
    try testing.expectEqual(@as(u8, 8), dev.capabilities.bits_per_channel);
}

test "a device is used through the interface without knowing which device it is" {
    // The seam property: code holds a Device and drives it the same way whatever is
    // behind it — here the software device, in production the GPU.
    var nodes = [_]Node{.{ .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .secure = true }};
    const tree: Tree = .{ .nodes = &nodes };
    const list = solidList(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const lists = [_]DisplayList{&list};

    var layer_buf: [4]Layer = undefined;
    var software = SoftwareDevice.init(testing.allocator, 8, 8, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, &layer_buf);
    defer software.deinit();
    const dev: Device = software.device();

    // Into a capture, the secure node is withheld: the image stays the background.
    try dev.submit(.{ .tree = tree, .lists = &lists, .target = .capture });
    try dev.present();
    try testing.expectEqual(Target.capture, software.last_target.?);
    try testing.expectEqual(@as(u8, 0), software.image.?.get(4, 4).r); // secure content not composited into a capture
}
