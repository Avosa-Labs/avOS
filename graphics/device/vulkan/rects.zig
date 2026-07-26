//! Compositing the retained tree's layers on the GPU as coloured rectangles.
//!
//! The compositor flattens its scene into an ordered list of layers, each a rectangle in the
//! frame. This draws that list on the GPU: one quad per layer, its clip-space position and colour
//! supplied as a push constant, painted back to front into an `offscreen.Target` and read back. It
//! is the bridge from the compositor's layer list to a GPU frame — the solid-fill path
//! (backgrounds, scrims, solid surfaces) rendered by the device rather than the software
//! rasteriser. The richer display-list content a layer can hold (rounded corners, gradients, text)
//! is the raster engine adapter's job on this same device; this is the geometry spine it sits on.
//!
//! Shaders are pre-compiled to SPIR-V and embedded.

const std = @import("std");
const c = @import("bindings.zig").c;
const device_mod = @import("device.zig");
const offscreen = @import("offscreen.zig");
const shader = @import("shader.zig");

const Error = offscreen.Error;
pub const Frame = offscreen.Frame;
pub const Rgba = offscreen.Rgba;

const vertex_spirv align(4) = @embedFile("shaders/rect.vert.spv").*;
const fragment_spirv align(4) = @embedFile("shaders/rect.frag.spv").*;

/// A layer to fill: its rectangle in pixels (top-left origin) and its colour. This is what a
/// flattened compositor layer contributes to a solid-fill GPU frame.
pub const Fill = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: [4]f32,
};

// The push constant a draw carries: the quad's clip-space rectangle and its colour.
const Push = extern struct {
    rect: [4]f32,
    color: [4]f32,
};

/// Composites `fills` (back to front) over a `clear` background into a `width`×`height` frame on
/// the GPU and reads it back. The returned frame's pixels are owned by `gpa`.
pub fn composite(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32, fills: []const Fill) Error!Frame {
    var target = try offscreen.Target.init(device, width, height);
    defer target.deinit();

    const cmd_bind_pipeline = try offscreen.req(device, c.PFN_vkCmdBindPipeline, "vkCmdBindPipeline");
    const cmd_push_constants = try offscreen.req(device, c.PFN_vkCmdPushConstants, "vkCmdPushConstants");
    const cmd_draw = try offscreen.req(device, c.PFN_vkCmdDraw, "vkCmdDraw");

    var pipeline = try shader.Pipeline.init(device, target.render_pass, width, height, &vertex_spirv, &fragment_spirv, @sizeOf(Push), c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, false);
    defer pipeline.deinit(device);

    const cmd = try target.beginPass(clear);
    cmd_bind_pipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);

    // One quad per fill, back to front, positioned in clip space from its pixel rectangle.
    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);
    for (fills) |fill| {
        const push = Push{
            .rect = .{
                fill.x / fw * 2.0 - 1.0, // left edge, pixels → clip space
                fill.y / fh * 2.0 - 1.0, // top edge
                fill.width / fw * 2.0, // width in clip units
                fill.height / fh * 2.0, // height in clip units
            },
            .color = fill.color,
        };
        cmd_push_constants(cmd, pipeline.layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Push), &push);
        cmd_draw(cmd, 4, 1, 0, 0);
    }
    return target.endAndReadback(gpa);
}

// --- Tests (real GPU compositing; strict on the lavapipe lane) ---

const testing = std.testing;
const env = @import("env.zig");
const instance_mod = @import("instance.zig");

test "layers composite as solid rectangles, back to front, over the clear" {
    var instance = instance_mod.Instance.create("rects-test") catch return;
    defer instance.deinit();
    var device = device_mod.Device.create(&instance, testing.allocator) catch {
        if (env.deviceRequired()) return error.VulkanCallFailed;
        return;
    };
    defer device.deinit();

    // A red left half, then a blue square over the top-left corner drawn on top of it.
    const fills = [_]Fill{
        .{ .x = 0, .y = 0, .width = 32, .height = 64, .color = .{ 1, 0, 0, 1 } }, // red left half
        .{ .x = 0, .y = 0, .width = 16, .height = 16, .color = .{ 0, 0, 1, 1 } }, // blue corner, on top
    };
    var frame = try composite(&device, testing.allocator, 64, 64, .{ 0, 0, 0, 1 }, &fills);
    defer frame.deinit(testing.allocator);

    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 }, frame.at(8, 8)); // blue, drawn last
    try testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, frame.at(24, 40)); // red left half
    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 }, frame.at(48, 40)); // right half: clear
}
