//! Rounded rectangles on the GPU — the design's primary surface primitive.
//!
//! Every card, sheet, and control in the design is a rounded rectangle, so this is the shape the
//! GPU renderer has to get right before anything else. Each rounded rect is drawn as a quad whose
//! fragment stage computes the signed distance to the rounded box and turns it into a one-pixel
//! antialiased coverage, so the corners are cut cleanly rather than squared off. Fills are blended
//! back to front over the cleared background into an `offscreen.Target`, then read back. A
//! purpose-built primitive like this is what the constrained design needs — rounded fills,
//! gradients, and glyphs — rather than a general vector engine.
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

const vertex_spirv align(4) = @embedFile("shaders/rounded.vert.spv").*;
const fragment_spirv align(4) = @embedFile("shaders/rounded.frag.spv").*;

/// A rounded rectangle to fill: its rectangle in pixels (top-left origin), corner radius in
/// pixels, and a vertical gradient from `top` to `bottom`. A solid card passes equal colours.
/// This is what a designed card contributes to a GPU frame.
pub const Card = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,
    top: [4]f32,
    bottom: [4]f32,

    /// A solid card: the same colour top and bottom.
    pub fn solid(x: f32, y: f32, width: f32, height: f32, radius: f32, color: [4]f32) Card {
        return .{ .x = x, .y = y, .width = width, .height = height, .radius = radius, .top = color, .bottom = color };
    }
};

// The push constant a draw carries: the quad's clip rectangle (for the vertex stage), the top and
// bottom gradient colours, the box centre and half-extent in pixels, and the corner radius.
const Push = extern struct {
    clip_rect: [4]f32,
    color_top: [4]f32,
    color_bottom: [4]f32,
    geom: [4]f32,
    radius: [4]f32,
};

/// Composites `cards` (back to front) over a `clear` background into a `width`×`height` frame on
/// the GPU and reads it back. The returned frame's pixels are owned by `gpa`.
pub fn composite(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32, cards: []const Card) Error!Frame {
    var target = try offscreen.Target.init(device, width, height);
    defer target.deinit();

    const cmd_bind_pipeline = try offscreen.req(device, c.PFN_vkCmdBindPipeline, "vkCmdBindPipeline");
    const cmd_push_constants = try offscreen.req(device, c.PFN_vkCmdPushConstants, "vkCmdPushConstants");
    const cmd_draw = try offscreen.req(device, c.PFN_vkCmdDraw, "vkCmdDraw");

    var pipeline = try shader.Pipeline.init(device, target.render_pass, width, height, &vertex_spirv, &fragment_spirv, @sizeOf(Push), c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, null);
    defer pipeline.deinit(device);

    const cmd = try target.beginPass(clear);
    cmd_bind_pipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);

    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);
    for (cards) |card| {
        const half_w = card.width / 2.0;
        const half_h = card.height / 2.0;
        const radius = @min(card.radius, @min(half_w, half_h)); // a radius cannot exceed the half-extent
        const push = Push{
            .clip_rect = .{ card.x / fw * 2.0 - 1.0, card.y / fh * 2.0 - 1.0, card.width / fw * 2.0, card.height / fh * 2.0 },
            .color_top = card.top,
            .color_bottom = card.bottom,
            .geom = .{ card.x + half_w, card.y + half_h, half_w, half_h },
            .radius = .{ radius, 0, 0, 0 },
        };
        cmd_push_constants(cmd, pipeline.layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Push), &push);
        cmd_draw(cmd, 4, 1, 0, 0);
    }
    return target.endAndReadback(gpa);
}

// --- Tests (real GPU rounded rects; strict on the lavapipe lane) ---

const testing = std.testing;
const env = @import("env.zig");
const instance_mod = @import("instance.zig");

test "a solid rounded card fills its interior and cuts its corners" {
    var instance = instance_mod.Instance.create("rounded-test") catch return;
    defer instance.deinit();
    var device = device_mod.Device.create(&instance, testing.allocator) catch {
        if (env.deviceRequired()) return error.VulkanCallFailed;
        return;
    };
    defer device.deinit();

    const cards = [_]Card{Card.solid(12, 12, 40, 40, 12, .{ 0, 1, 0, 1 })}; // green, on a black clear
    var frame = try composite(&device, testing.allocator, 64, 64, .{ 0, 0, 0, 1 }, &cards);
    defer frame.deinit(testing.allocator);

    const green = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const black = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    try testing.expectEqual(green, frame.at(32, 32)); // centre: filled
    try testing.expectEqual(green, frame.at(32, 14)); // top edge midpoint: filled (straight edge)
    try testing.expectEqual(black, frame.at(13, 13)); // near the box corner but outside the arc: cut
}

test "a card's vertical gradient runs from its top colour to its bottom colour" {
    var instance = instance_mod.Instance.create("gradient-test") catch return;
    defer instance.deinit();
    var device = device_mod.Device.create(&instance, testing.allocator) catch {
        if (env.deviceRequired()) return error.VulkanCallFailed;
        return;
    };
    defer device.deinit();

    // A full-frame card, red at the top grading to blue at the bottom.
    const cards = [_]Card{.{ .x = 0, .y = 0, .width = 64, .height = 64, .radius = 0, .top = .{ 1, 0, 0, 1 }, .bottom = .{ 0, 0, 1, 1 } }};
    var frame = try composite(&device, testing.allocator, 64, 64, .{ 0, 0, 0, 1 }, &cards);
    defer frame.deinit(testing.allocator);

    const near_top = frame.at(32, 2);
    const near_bottom = frame.at(32, 61);
    try testing.expect(near_top.r > 200 and near_top.b < 60); // top is red
    try testing.expect(near_bottom.b > 200 and near_bottom.r < 60); // bottom is blue
    try testing.expect(near_bottom.b > near_top.b); // blue grows downward
}
