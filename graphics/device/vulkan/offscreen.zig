//! A GPU frame with no display: clear a colour image, read it back, hand over the pixels.
//!
//! This is the first thing the device draws that a gate can look at — a static frame rendered
//! on the GPU and compared pixel for pixel, the headless render the whole conformance story
//! rests on. It allocates a colour image on the device, runs a render pass whose only work is
//! to clear it to a given colour, copies the result into a host-visible buffer, and reads that
//! buffer back into memory the caller owns. No window and no swapchain are involved; the image
//! is the frame, and the readback is what a pixel gate asserts against. Every Vulkan object it
//! creates is destroyed before it returns, on success and on error.
//!
//! Clearing is the whole draw here on purpose: it exercises image allocation, a render pass, a
//! command buffer, a queue submission, a fence, and a readback copy — the spine every later
//! frame (a pipeline drawing real geometry) hangs on — with nothing that can differ between
//! implementations, so the pixel it produces is exact.

const std = @import("std");
const c = @import("bindings.zig").c;
const device_mod = @import("device.zig");
const memory = @import("memory.zig");

pub const Error = error{ OutOfMemory, NoSuitableMemory, VulkanCallFailed };

pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// A frame read back from the GPU: RGBA8 pixels, row-major, owned by the caller's allocator.
pub const Frame = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(frame: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(frame.pixels);
    }

    /// The pixel at `(x, y)`.
    pub fn at(frame: Frame, x: u32, y: u32) Rgba {
        const i = (@as(usize, y) * frame.width + x) * 4;
        return .{ .r = frame.pixels[i], .g = frame.pixels[i + 1], .b = frame.pixels[i + 2], .a = frame.pixels[i + 3] };
    }
};

/// The colour format the offscreen frames render into: 8-bit UNORM, so a clear or a solid
/// fragment colour reads back as an exact byte value.
pub const format = c.VK_FORMAT_R8G8B8A8_UNORM;

/// Resolves a required device command, or fails. Shared with the pipeline renderer.
pub fn req(device: *device_mod.Device, comptime Fn: type, name: [*:0]const u8) Error!@typeInfo(Fn).optional.child {
    return device.proc(Fn, name) orelse error.VulkanCallFailed;
}

/// Turns a non-success VkResult into an error. Shared with the pipeline renderer.
pub fn check(result: c.VkResult) Error!void {
    if (result != c.VK_SUCCESS) return error.VulkanCallFailed;
}

/// Renders a frame cleared to `clear` (RGBA, each channel in [0,1]) at `width`×`height` on the
/// GPU and reads it back. The returned frame's pixels are owned by `gpa`.
pub fn renderClear(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32) Error!Frame {
    const create_image = try req(device, c.PFN_vkCreateImage, "vkCreateImage");
    const destroy_image = try req(device, c.PFN_vkDestroyImage, "vkDestroyImage");
    const image_mem_reqs = try req(device, c.PFN_vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
    const allocate_memory = try req(device, c.PFN_vkAllocateMemory, "vkAllocateMemory");
    const free_memory = try req(device, c.PFN_vkFreeMemory, "vkFreeMemory");
    const bind_image_memory = try req(device, c.PFN_vkBindImageMemory, "vkBindImageMemory");
    const create_view = try req(device, c.PFN_vkCreateImageView, "vkCreateImageView");
    const destroy_view = try req(device, c.PFN_vkDestroyImageView, "vkDestroyImageView");
    const create_render_pass = try req(device, c.PFN_vkCreateRenderPass, "vkCreateRenderPass");
    const destroy_render_pass = try req(device, c.PFN_vkDestroyRenderPass, "vkDestroyRenderPass");
    const create_framebuffer = try req(device, c.PFN_vkCreateFramebuffer, "vkCreateFramebuffer");
    const destroy_framebuffer = try req(device, c.PFN_vkDestroyFramebuffer, "vkDestroyFramebuffer");
    const create_buffer = try req(device, c.PFN_vkCreateBuffer, "vkCreateBuffer");
    const destroy_buffer = try req(device, c.PFN_vkDestroyBuffer, "vkDestroyBuffer");
    const buffer_mem_reqs = try req(device, c.PFN_vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
    const bind_buffer_memory = try req(device, c.PFN_vkBindBufferMemory, "vkBindBufferMemory");
    const create_command_pool = try req(device, c.PFN_vkCreateCommandPool, "vkCreateCommandPool");
    const destroy_command_pool = try req(device, c.PFN_vkDestroyCommandPool, "vkDestroyCommandPool");
    const allocate_command_buffers = try req(device, c.PFN_vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
    const begin_command_buffer = try req(device, c.PFN_vkBeginCommandBuffer, "vkBeginCommandBuffer");
    const end_command_buffer = try req(device, c.PFN_vkEndCommandBuffer, "vkEndCommandBuffer");
    const cmd_begin_render_pass = try req(device, c.PFN_vkCmdBeginRenderPass, "vkCmdBeginRenderPass");
    const cmd_end_render_pass = try req(device, c.PFN_vkCmdEndRenderPass, "vkCmdEndRenderPass");
    const cmd_copy_image_to_buffer = try req(device, c.PFN_vkCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer");
    const create_fence = try req(device, c.PFN_vkCreateFence, "vkCreateFence");
    const destroy_fence = try req(device, c.PFN_vkDestroyFence, "vkDestroyFence");
    const wait_for_fences = try req(device, c.PFN_vkWaitForFences, "vkWaitForFences");
    const queue_submit = try req(device, c.PFN_vkQueueSubmit, "vkQueueSubmit");
    const map_memory = try req(device, c.PFN_vkMapMemory, "vkMapMemory");
    const unmap_memory = try req(device, c.PFN_vkUnmapMemory, "vkUnmapMemory");

    const dev = device.handle;

    // The colour image the frame is rendered into: device-local, a colour attachment and a
    // transfer source (so it can be copied out).
    var image_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: c.VkImage = null;
    try check(create_image(dev, &image_info, null, &image));
    defer destroy_image(dev, image, null);

    var image_reqs: c.VkMemoryRequirements = undefined;
    image_mem_reqs(dev, image, &image_reqs);
    const image_type = memory.typeIndex(device.memory_properties, image_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoSuitableMemory;
    var image_alloc = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = image_reqs.size,
        .memoryTypeIndex = image_type,
    };
    var image_memory: c.VkDeviceMemory = null;
    try check(allocate_memory(dev, &image_alloc, null, &image_memory));
    defer free_memory(dev, image_memory, null);
    try check(bind_image_memory(dev, image, image_memory, 0));

    // A view of the whole colour image.
    var view_info = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{ .r = c.VK_COMPONENT_SWIZZLE_IDENTITY, .g = c.VK_COMPONENT_SWIZZLE_IDENTITY, .b = c.VK_COMPONENT_SWIZZLE_IDENTITY, .a = c.VK_COMPONENT_SWIZZLE_IDENTITY },
        .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
    };
    var view: c.VkImageView = null;
    try check(create_view(dev, &view_info, null, &view));
    defer destroy_view(dev, view, null);

    // A render pass that clears the colour attachment and leaves it ready to copy out.
    var attachment = c.VkAttachmentDescription{
        .format = format,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    };
    var attachment_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    var subpass = c.VkSubpassDescription{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment_ref,
    };
    var render_pass_info = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
    };
    var render_pass: c.VkRenderPass = null;
    try check(create_render_pass(dev, &render_pass_info, null, &render_pass));
    defer destroy_render_pass(dev, render_pass, null);

    var framebuffer_info = c.VkFramebufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = render_pass,
        .attachmentCount = 1,
        .pAttachments = &view,
        .width = width,
        .height = height,
        .layers = 1,
    };
    var framebuffer: c.VkFramebuffer = null;
    try check(create_framebuffer(dev, &framebuffer_info, null, &framebuffer));
    defer destroy_framebuffer(dev, framebuffer, null);

    // The host-visible buffer the frame is copied into for readback.
    const byte_count: c.VkDeviceSize = @as(c.VkDeviceSize, width) * height * 4;
    var buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = byte_count,
        .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };
    var buffer: c.VkBuffer = null;
    try check(create_buffer(dev, &buffer_info, null, &buffer));
    defer destroy_buffer(dev, buffer, null);

    var buffer_reqs: c.VkMemoryRequirements = undefined;
    buffer_mem_reqs(dev, buffer, &buffer_reqs);
    const buffer_type = memory.typeIndex(
        device.memory_properties,
        buffer_reqs.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    ) orelse return error.NoSuitableMemory;
    var buffer_alloc = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = buffer_reqs.size,
        .memoryTypeIndex = buffer_type,
    };
    var buffer_memory: c.VkDeviceMemory = null;
    try check(allocate_memory(dev, &buffer_alloc, null, &buffer_memory));
    defer free_memory(dev, buffer_memory, null);
    try check(bind_buffer_memory(dev, buffer, buffer_memory, 0));

    // Record: clear the image via the render pass, then copy it into the readback buffer.
    var pool_info = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = device.queue_family,
    };
    var command_pool: c.VkCommandPool = null;
    try check(create_command_pool(dev, &pool_info, null, &command_pool));
    defer destroy_command_pool(dev, command_pool, null);

    var command_buffer_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var command_buffer: c.VkCommandBuffer = null;
    try check(allocate_command_buffers(dev, &command_buffer_info, &command_buffer));

    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(begin_command_buffer(command_buffer, &begin_info));

    var clear_value = c.VkClearValue{ .color = .{ .float32 = clear } };
    var render_pass_begin = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = render_pass,
        .framebuffer = framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
        .clearValueCount = 1,
        .pClearValues = &clear_value,
    };
    cmd_begin_render_pass(command_buffer, &render_pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    cmd_end_render_pass(command_buffer);

    var region = c.VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
    cmd_copy_image_to_buffer(command_buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    try check(end_command_buffer(command_buffer));

    // Submit and wait.
    var fence_info = c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    var fence: c.VkFence = null;
    try check(create_fence(dev, &fence_info, null, &fence));
    defer destroy_fence(dev, fence, null);

    var submit = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };
    try check(queue_submit(device.graphics_queue, 1, &submit, fence));
    try check(wait_for_fences(dev, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));

    // Read the frame back into caller-owned memory.
    var mapped: ?*anyopaque = null;
    try check(map_memory(dev, buffer_memory, 0, byte_count, 0, &mapped));
    const source: [*]const u8 = @ptrCast(mapped.?);
    const pixels = try gpa.alloc(u8, @intCast(byte_count));
    @memcpy(pixels, source[0..@intCast(byte_count)]);
    unmap_memory(dev, buffer_memory);

    return .{ .width = width, .height = height, .pixels = pixels };
}

// --- Tests (a real GPU frame; strict on the lavapipe lane) ---

const testing = std.testing;
const env = @import("env.zig");
const instance_mod = @import("instance.zig");

test "a cleared frame reads back the exact clear colour, everywhere" {
    var instance = instance_mod.Instance.create("offscreen-test") catch {
        return; // no implementation here — the device tests cover the typed absence
    };
    defer instance.deinit();
    var device = device_mod.Device.create(&instance, testing.allocator) catch {
        if (env.deviceRequired()) return error.VulkanCallFailed;
        return;
    };
    defer device.deinit();

    // Clear to magenta: channels are 0 or 1, so the 8-bit result is exact (no rounding).
    var frame = try renderClear(&device, testing.allocator, 16, 8, .{ 1.0, 0.0, 1.0, 1.0 });
    defer frame.deinit(testing.allocator);

    const magenta = Rgba{ .r = 255, .g = 0, .b = 255, .a = 255 };
    try testing.expectEqual(magenta, frame.at(0, 0)); // a corner
    try testing.expectEqual(magenta, frame.at(15, 7)); // the opposite corner
    try testing.expectEqual(magenta, frame.at(8, 4)); // the middle
}
