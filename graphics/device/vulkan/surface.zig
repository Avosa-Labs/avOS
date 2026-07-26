//! A designed surface composed on the GPU: a rounded card with text drawn onto it (Checkpoint G1).
//!
//! The primitives each prove themselves in isolation; this proves they compose into one frame the
//! way a real surface does — a rounded (optionally gradient) card, then text drawn over it, both
//! in a single render pass, blended in order, and read back for a pixel gate. It is the smallest
//! thing that is recognisably a designed surface rendered by the GPU device rather than the
//! software rasteriser: a card, and ink on the card, with the card showing through where the ink
//! is not. The two pipelines share the one offscreen target and render pass.
//!
//! Shaders are pre-compiled to SPIR-V and embedded.

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

const card_vertex_spirv align(4) = @embedFile("shaders/rounded.vert.spv").*;
const card_fragment_spirv align(4) = @embedFile("shaders/rounded.frag.spv").*;
const text_vertex_spirv align(4) = @embedFile("shaders/textured.vert.spv").*;
const text_fragment_spirv align(4) = @embedFile("shaders/textured.frag.spv").*;

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };

/// A rounded card: rectangle in pixels, corner radius, and a vertical gradient (equal colours for
/// a solid fill).
pub const Card = struct {
    rect: Rect,
    radius: f32,
    top: [4]f32,
    bottom: [4]f32,
};

/// Text drawn onto the card: a coverage texture, where to place it, and the ink colour.
pub const Text = struct {
    texture: *const Texture,
    rect: Rect,
    color: [4]f32,
};

const CardPush = extern struct {
    clip_rect: [4]f32,
    color_top: [4]f32,
    color_bottom: [4]f32,
    geom: [4]f32,
    radius: [4]f32,
};

const TextPush = extern struct {
    clip_rect: [4]f32,
    color: [4]f32,
};

fn clipRect(rect: Rect, fw: f32, fh: f32) [4]f32 {
    return .{ rect.x / fw * 2.0 - 1.0, rect.y / fh * 2.0 - 1.0, rect.width / fw * 2.0, rect.height / fh * 2.0 };
}

/// Composes `card` then `text` over a `clear` background into a `width`×`height` frame on the GPU
/// and reads it back. The returned frame's pixels are owned by `gpa`.
pub fn render(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32, card: Card, text: Text) Error!Frame {
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

    // The text's combined-image-sampler descriptor.
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

    var image_info = c.VkDescriptorImageInfo{ .sampler = text.texture.sampler, .imageView = text.texture.view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    var write = c.VkWriteDescriptorSet{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = descriptor_set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &image_info };
    update_sets(dev, 1, &write, 0, null);

    var target = try offscreen.Target.init(device, width, height);
    defer target.deinit();

    var card_pipeline = try shader.Pipeline.init(device, target.render_pass, width, height, &card_vertex_spirv, &card_fragment_spirv, @sizeOf(CardPush), c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, null);
    defer card_pipeline.deinit(device);
    var text_pipeline = try shader.Pipeline.init(device, target.render_pass, width, height, &text_vertex_spirv, &text_fragment_spirv, @sizeOf(TextPush), c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, set_layout);
    defer text_pipeline.deinit(device);

    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);
    const half_w = card.rect.width / 2.0;
    const half_h = card.rect.height / 2.0;
    const card_push = CardPush{
        .clip_rect = clipRect(card.rect, fw, fh),
        .color_top = card.top,
        .color_bottom = card.bottom,
        .geom = .{ card.rect.x + half_w, card.rect.y + half_h, half_w, half_h },
        .radius = .{ @min(card.radius, @min(half_w, half_h)), 0, 0, 0 },
    };
    const text_push = TextPush{ .clip_rect = clipRect(text.rect, fw, fh), .color = text.color };

    const cmd = try target.beginPass(clear);
    cmd_bind_pipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, card_pipeline.handle);
    cmd_push_constants(cmd, card_pipeline.layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(CardPush), &card_push);
    cmd_draw(cmd, 4, 1, 0, 0);

    cmd_bind_pipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, text_pipeline.handle);
    cmd_bind_descriptor_sets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, text_pipeline.layout, 0, 1, &descriptor_set, 0, null);
    cmd_push_constants(cmd, text_pipeline.layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(TextPush), &text_push);
    cmd_draw(cmd, 4, 1, 0, 0);

    return target.endAndReadback(gpa);
}

// --- Tests (a composed designed surface; strict on the lavapipe lane) ---

const testing = std.testing;
const env = @import("env.zig");
const instance_mod = @import("instance.zig");

test "a card with text composes: card fills, ink sits on it, card shows through the gaps" {
    var instance = instance_mod.Instance.create("surface-test") catch return;
    defer instance.deinit();
    var device = device_mod.Device.create(&instance, testing.allocator) catch {
        if (env.deviceRequired()) return error.VulkanCallFailed;
        return;
    };
    defer device.deinit();

    // Ink: a 2x1 coverage, left texel inked, right empty.
    const coverage = [_]u8{ 255, 0 };
    var ink = try Texture.upload(&device, 2, 1, &coverage);
    defer ink.deinit(&device);

    // A solid green rounded card almost filling the frame, with white "text" across its middle.
    const card = Card{ .rect = .{ .x = 4, .y = 4, .width = 56, .height = 56 }, .radius = 10, .top = .{ 0, 1, 0, 1 }, .bottom = .{ 0, 1, 0, 1 } };
    const text = Text{ .texture = &ink, .rect = .{ .x = 8, .y = 24, .width = 48, .height = 12 }, .color = .{ 1, 1, 1, 1 } };
    var frame = try render(&device, testing.allocator, 64, 64, .{ 0, 0, 0, 1 }, card, text);
    defer frame.deinit(testing.allocator);

    const green = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    try testing.expectEqual(green, frame.at(32, 50)); // card interior, below the text
    try testing.expectEqual(white, frame.at(16, 30)); // ink's left texel, drawn over the card
    try testing.expectEqual(green, frame.at(44, 30)); // ink's right texel is empty: the card shows through
    try testing.expectEqual(black, frame.at(1, 1)); // outside the card: the clear background
}
