//! A compositor scene drawn on the GPU: the compositor's display lists become device pixels.
//!
//! `gpu_scene.encode` reduces a retained tree and its display lists to an ordered list of
//! world-space quads — the same flatten, cull, and opacity the software rasteriser applies. This
//! is the other half: it hands those quads to the Vulkan device, which draws every one of them in
//! a single pass. The design's four paint commands are all a rounded rectangle to the GPU, and the
//! device's `rounded.composite` already batches a rounded-rectangle list back to front, so the
//! whole compositor frame is one call. It is the live path a shell frame takes to the GPU rather
//! than the software framebuffer, proven on a real device by reading the pixels back.
//!
//! Built only where the Vulkan engine is vendored. What it does not yet carry — a per-quad scissor
//! for the clip rectangle, and the non-`normal` blend modes — is the device's remaining debt,
//! recorded on each quad (see `gpu_scene`), not lost here.

const std = @import("std");
const vk = @import("vulkan");
const gfx = @import("graphics");

const gpu_scene = gfx.gpu_scene;

pub const Frame = vk.rounded.Frame;
pub const Rgba = vk.offscreen.Rgba;
pub const Tree = gpu_scene.Tree;
pub const Layer = gpu_scene.Layer;
pub const Target = gpu_scene.Target;
pub const DisplayList = gpu_scene.DisplayList;

pub const Error = vk.offscreen.Error || error{OutOfMemory};

/// Encodes the visible layers of `tree` (with per-node display lists `lists`) to quads, draws them
/// all in one pass on `device` over a `clear` background into a `width`×`height` frame, and reads
/// the frame back. `layer_buffer` sizes the flatten pass. The returned frame's pixels are owned by
/// `gpa`.
pub fn renderTree(
    device: *vk.Device,
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    clear: [4]f32,
    tree: Tree,
    lists: []const DisplayList,
    layer_buffer: []Layer,
    target_kind: Target,
) Error!Frame {
    const quads = try gpu_scene.encode(gpa, tree, lists, layer_buffer, target_kind);
    defer gpa.free(quads);

    const cards = try gpa.alloc(vk.rounded.Card, quads.len);
    defer gpa.free(cards);
    for (quads, cards) |quad, *card| {
        card.* = .{
            .x = quad.x,
            .y = quad.y,
            .width = quad.width,
            .height = quad.height,
            .radius = quad.radius,
            .top = quad.top,
            .bottom = quad.bottom,
        };
    }

    return vk.rounded.composite(device, gpa, width, height, clear, cards);
}

// --- Tests (a real compositor scene on the GPU; strict on the lavapipe lane) ---

const testing = std.testing;
const scene = gfx.scene_tree;
const paint = gfx.paint;

fn solidList(rect: paint.Rect, colour: gfx.framebuffer.Rgba) [1]paint.Command {
    return .{.{ .solid = .{ .rect = rect, .colour = colour } }};
}

test "a two-layer scene draws through the device at the layers' world positions" {
    var instance = vk.Instance.create("gpu-composite-test") catch return;
    defer instance.deinit();
    var device = vk.Device.create(&instance, testing.allocator) catch return;
    defer device.deinit();

    // A red background node filling the frame, and a green node translated to (20,20).
    var nodes = [_]scene.Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 64, .height = 64 } },
        .{ .parent = 0, .transform = scene.Transform.translate(20, 20), .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const bg = solidList(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, .{ .r = 220, .g = 0, .b = 0, .a = 255 });
    const fg = solidList(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ .r = 0, .g = 220, .b = 0, .a = 255 });
    const lists = [_]DisplayList{ &bg, &fg };

    var layer_buf: [8]Layer = undefined;
    var frame = try renderTree(&device, testing.allocator, 64, 64, .{ 0, 0, 0, 1 }, tree, &lists, &layer_buf, .screen);
    defer frame.deinit(testing.allocator);

    const bg_pixel = frame.at(4, 4); // outside the green node: the red background
    try testing.expect(bg_pixel.r > 200 and bg_pixel.g < 40);
    const fg_pixel = frame.at(30, 30); // inside the green node at its world offset
    try testing.expect(fg_pixel.g > 200 and fg_pixel.r < 40);
}
