//! Drawing a coverage texture as coloured ink — a glyph or a mask on the GPU.
//!
//! Text on the GPU is a coverage texture sampled while drawing a quad: the atlas holds how much
//! ink is at each texel, and the fragment stage multiplies that coverage by the ink colour, so
//! the glyph blends onto whatever is beneath it. This binds a `Texture` through a descriptor set,
//! draws a quad at a pixel rectangle, and reads the frame back. It is the last of the design's
//! primitives — rounded gradient fills, and now text — none of which needs a general vector
//! engine. The FreeType adapter produces the coverage; here it becomes pixels.

const std = @import("std");
const c = @import("bindings.zig").c;
const device_mod = @import("device.zig");
const offscreen = @import("offscreen.zig");
const shader = @import("shader.zig");
const texture_mod = @import("texture.zig");

const Error = offscreen.Error;
pub const Frame = offscreen.Frame;
pub const Rgba = offscreen.Rgba;
pub const Texture = texture_mod.Texture;

const vertex_spirv align(4) = @embedFile("shaders/textured.vert.spv").*;
const fragment_spirv align(4) = @embedFile("shaders/textured.frag.spv").*;

/// A pixel rectangle to draw the texture into (top-left origin).
pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };

const Push = extern struct {
    clip_rect: [4]f32,
    color: [4]f32,
};

/// Draws `texture` as `color` ink into `dest` over a `clear` background at `width`×`height`, and
/// reads the frame back. The returned frame's pixels are owned by `gpa`.
pub fn draw(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32, texture: *const Texture, dest: Rect, color: [4]f32) Error!Frame {
    const dev = device.handle;
    const create_set_layout = try offscreen.req(device, c.PFN_vkCreateDescriptorSetLayout, "vkCreateDescriptorSetLayout");
    const destroy_set_layout = try offscreen.req(device, c.PFN_vkDestroyDescriptorSetLayout, "vkDestroyDescriptorSetLayout");
    const create_pool = try offscreen.req(device, c.PFN_vkCreateDescriptorPool, "vkCreateDescriptorPool");
    const destroy_pool = try offscreen.req(device, c.PFN_vkDestroyDescriptorPool, "vkDestroyDescriptorPool");
    const allocate_sets = try offscreen.req(device, c.PFN_vkAllocateDescriptorSets, "vkAllocateDescriptorSets");
    const update_sets = try offscreen.req(device, c.PFN_vkUpdateDescriptorSets, "vkUpdateDescriptorSets");
    const cmd_bind_pipeline = try offscreen.req(device, c.PFN_vkCmdBindPipeline, "vkCmdBindPipeline");
    const cmd_bind_descriptor_sets = try offscreen.req(device, c.PFN_vkCmdBindDescriptorSets, "vkCmdBindDescriptorSets");
    const cmd_push_constants = try offscreen.req(device, c.PFN_vkCmdPushConstants, "vkCmdPushConstants");
    const cmd_draw = try offscreen.req(device, c.PFN_vkCmdDraw, "vkCmdDraw");

    // A descriptor set layout with one combined image sampler for the fragment stage.
    var binding = c.VkDescriptorSetLayoutBinding{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT };
    var set_layout_info = c.VkDescriptorSetLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &binding };
    var set_layout: c.VkDescriptorSetLayout = null;
    try offscreen.check(create_set_layout(dev, &set_layout_info, null, &set_layout));
    defer destroy_set_layout(dev, set_layout, null);

    var pool_size = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 };
    var pool_info = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size };
    var pool: c.VkDescriptorPool = null;
    try offscreen.check(create_pool(dev, &pool_info, null, &pool));
    defer destroy_pool(dev, pool, null);

    var set_alloc = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &set_layout };
    var descriptor_set: c.VkDescriptorSet = null;
    try offscreen.check(allocate_sets(dev, &set_alloc, &descriptor_set));

    var image_info = c.VkDescriptorImageInfo{ .sampler = texture.sampler, .imageView = texture.view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    var write = c.VkWriteDescriptorSet{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = descriptor_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &image_info,
    };
    update_sets(dev, 1, &write, 0, null);

    var target = try offscreen.Target.init(device, width, height);
    defer target.deinit();

    var pipeline = try shader.Pipeline.init(device, target.render_pass, width, height, &vertex_spirv, &fragment_spirv, @sizeOf(Push), c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, set_layout);
    defer pipeline.deinit(device);

    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);
    const push = Push{
        .clip_rect = .{ dest.x / fw * 2.0 - 1.0, dest.y / fh * 2.0 - 1.0, dest.width / fw * 2.0, dest.height / fh * 2.0 },
        .color = color,
    };

    const cmd = try target.beginPass(clear);
    cmd_bind_pipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
    cmd_bind_descriptor_sets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.layout, 0, 1, &descriptor_set, 0, null);
    cmd_push_constants(cmd, pipeline.layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Push), &push);
    cmd_draw(cmd, 4, 1, 0, 0);
    return target.endAndReadback(gpa);
}

// --- Tests (a sampled coverage draw; strict on the lavapipe lane) ---

const testing = std.testing;
const env = @import("env.zig");
const instance_mod = @import("instance.zig");

test "a coverage texture draws as ink where it is opaque and shows the background where it is not" {
    var instance = instance_mod.Instance.create("glyph-test") catch return;
    defer instance.deinit();
    var device = device_mod.Device.create(&instance, testing.allocator) catch {
        if (env.deviceRequired()) return error.VulkanCallFailed;
        return;
    };
    defer device.deinit();

    // A 2x1 coverage: the left texel is fully inked, the right is empty.
    const coverage = [_]u8{ 255, 0 };
    var texture = try Texture.upload(&device, 2, 1, &coverage);
    defer texture.deinit(&device);

    // Draw it filling a 64x64 frame in green over a black clear.
    var frame = try draw(&device, testing.allocator, 64, 64, .{ 0, 0, 0, 1 }, &texture, .{ .x = 0, .y = 0, .width = 64, .height = 64 }, .{ 0, 1, 0, 1 });
    defer frame.deinit(testing.allocator);

    try testing.expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 }, frame.at(16, 32)); // left texel: inked green
    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 }, frame.at(48, 32)); // right texel: background
}
