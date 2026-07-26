//! A graphics pipeline drawing real geometry into an offscreen frame, read back for a gate.
//!
//! Clearing an image (see `offscreen`) proves the submission scaffold; this proves the part that
//! actually rasterises. It builds a minimal graphics pipeline — a vertex stage that emits a
//! triangle from the vertex index and a fragment stage that writes a solid colour — and draws it
//! into an `offscreen.Target`, then reads the result back. The triangle covers the middle of the
//! frame and leaves the corners on the cleared background, so the readback distinguishes
//! rasterised geometry from the clear: the centre is the triangle's colour, a corner is the clear.
//!
//! The shaders are compiled to SPIR-V ahead of time and embedded, so no shader compiler is in the
//! build. Every Vulkan object it creates is destroyed before the function returns.

const std = @import("std");
const c = @import("bindings.zig").c;
const device_mod = @import("device.zig");
const offscreen = @import("offscreen.zig");
const shader = @import("shader.zig");

const Error = offscreen.Error;
pub const Frame = offscreen.Frame;
pub const Rgba = offscreen.Rgba;

const vertex_spirv align(4) = @embedFile("shaders/triangle.vert.spv").*;
const fragment_spirv align(4) = @embedFile("shaders/triangle.frag.spv").*;

/// Draws the embedded triangle into a `width`×`height` frame cleared to `clear`, and reads it
/// back. The returned frame's pixels are owned by `gpa`.
pub fn renderTriangle(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32) Error!Frame {
    var target = try offscreen.Target.init(device, width, height);
    defer target.deinit();

    const cmd_bind_pipeline = try offscreen.req(device, c.PFN_vkCmdBindPipeline, "vkCmdBindPipeline");
    const cmd_draw = try offscreen.req(device, c.PFN_vkCmdDraw, "vkCmdDraw");

    var pipeline = try shader.Pipeline.init(device, target.render_pass, width, height, &vertex_spirv, &fragment_spirv, 0, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, false, null);
    defer pipeline.deinit(device);

    const cmd = try target.beginPass(clear);
    cmd_bind_pipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
    cmd_draw(cmd, 3, 1, 0, 0);
    return target.endAndReadback(gpa);
}

// --- Tests (a real GPU draw; strict on the lavapipe lane) ---

const testing = std.testing;
const env = @import("env.zig");
const instance_mod = @import("instance.zig");

test "a drawn triangle covers the centre and leaves the corners on the clear colour" {
    var instance = instance_mod.Instance.create("pipeline-test") catch return;
    defer instance.deinit();
    var device = device_mod.Device.create(&instance, testing.allocator) catch {
        if (env.deviceRequired()) return error.VulkanCallFailed;
        return;
    };
    defer device.deinit();

    var frame = try renderTriangle(&device, testing.allocator, 64, 64, .{ 0.0, 0.0, 0.0, 1.0 });
    defer frame.deinit(testing.allocator);

    const green = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const black = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    try testing.expectEqual(green, frame.at(32, 40)); // inside the triangle (lower centre)
    try testing.expectEqual(black, frame.at(1, 1)); // top-left corner: outside
    try testing.expectEqual(black, frame.at(62, 1)); // top-right corner: outside
}
