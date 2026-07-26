//! An offscreen colour target and a readback: the scaffold every headless GPU frame shares.
//!
//! A frame with no display is always the same shape underneath: a device-local colour image with
//! a render pass and framebuffer, a host-visible buffer to copy it into, and a command buffer to
//! drive the pass and the copy. `Target` is that scaffold, created once and torn down cleanly, so
//! the frame renderers above it — a clear, a triangle, the compositor's layer quads — differ only
//! in what they record between the render pass beginning and its end. A caller records its draws
//! against the command buffer `beginPass` returns and creates any pipeline against `render_pass`,
//! then `endAndReadback` closes the pass, copies the image out, submits, waits, and reads the
//! result back into caller-owned pixels.
//!
//! This is the headless render the whole conformance story rests on. `renderClear` is the
//! simplest use — no draws at all — and doubles as the proof that the scaffold itself is sound.

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

/// The colour format offscreen frames render into: 8-bit UNORM, so a clear or a solid fragment
/// colour reads back as an exact byte value.
pub const format = c.VK_FORMAT_R8G8B8A8_UNORM;

/// Resolves a required device command, or fails. Shared with the frame renderers.
pub fn req(device: *device_mod.Device, comptime Fn: type, name: [*:0]const u8) Error!@typeInfo(Fn).optional.child {
    return device.proc(Fn, name) orelse error.VulkanCallFailed;
}

/// Turns a non-success VkResult into an error. Shared with the frame renderers.
pub fn check(result: c.VkResult) Error!void {
    if (result != c.VK_SUCCESS) return error.VulkanCallFailed;
}

/// An offscreen colour target: the shared image, render pass, framebuffer, readback buffer, and
/// command buffer a headless frame is built on. A renderer creates any pipeline against
/// `render_pass`, records draws between `beginPass` and `endAndReadback`, and gets the pixels back.
pub const Target = struct {
    device: *device_mod.Device,
    width: u32,
    height: u32,
    byte_count: c.VkDeviceSize,
    image: c.VkImage,
    image_memory: c.VkDeviceMemory,
    view: c.VkImageView,
    render_pass: c.VkRenderPass,
    framebuffer: c.VkFramebuffer,
    buffer: c.VkBuffer,
    buffer_memory: c.VkDeviceMemory,
    command_pool: c.VkCommandPool,
    command_buffer: c.VkCommandBuffer,

    pub fn init(device: *device_mod.Device, width: u32, height: u32) Error!Target {
        const dev = device.handle;
        const create_image = try req(device, c.PFN_vkCreateImage, "vkCreateImage");
        const image_mem_reqs = try req(device, c.PFN_vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
        const allocate_memory = try req(device, c.PFN_vkAllocateMemory, "vkAllocateMemory");
        const bind_image_memory = try req(device, c.PFN_vkBindImageMemory, "vkBindImageMemory");
        const create_view = try req(device, c.PFN_vkCreateImageView, "vkCreateImageView");
        const create_render_pass = try req(device, c.PFN_vkCreateRenderPass, "vkCreateRenderPass");
        const create_framebuffer = try req(device, c.PFN_vkCreateFramebuffer, "vkCreateFramebuffer");
        const create_buffer = try req(device, c.PFN_vkCreateBuffer, "vkCreateBuffer");
        const buffer_mem_reqs = try req(device, c.PFN_vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
        const bind_buffer_memory = try req(device, c.PFN_vkBindBufferMemory, "vkBindBufferMemory");
        const create_command_pool = try req(device, c.PFN_vkCreateCommandPool, "vkCreateCommandPool");
        const allocate_command_buffers = try req(device, c.PFN_vkAllocateCommandBuffers, "vkAllocateCommandBuffers");

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
        errdefer destroyOne(device, c.PFN_vkDestroyImage, "vkDestroyImage", image);

        var image_reqs: c.VkMemoryRequirements = undefined;
        image_mem_reqs(dev, image, &image_reqs);
        const image_type = memory.typeIndex(device.memory_properties, image_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoSuitableMemory;
        var image_alloc = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = image_reqs.size, .memoryTypeIndex = image_type };
        var image_memory: c.VkDeviceMemory = null;
        try check(allocate_memory(dev, &image_alloc, null, &image_memory));
        errdefer freeOne(device, image_memory);
        try check(bind_image_memory(dev, image, image_memory, 0));

        var view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        };
        var view: c.VkImageView = null;
        try check(create_view(dev, &view_info, null, &view));
        errdefer destroyOne(device, c.PFN_vkDestroyImageView, "vkDestroyImageView", view);

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
        var subpass = c.VkSubpassDescription{ .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &attachment_ref };
        var render_pass_info = c.VkRenderPassCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass };
        var render_pass: c.VkRenderPass = null;
        try check(create_render_pass(dev, &render_pass_info, null, &render_pass));
        errdefer destroyOne(device, c.PFN_vkDestroyRenderPass, "vkDestroyRenderPass", render_pass);

        var framebuffer_info = c.VkFramebufferCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = render_pass, .attachmentCount = 1, .pAttachments = &view, .width = width, .height = height, .layers = 1 };
        var framebuffer: c.VkFramebuffer = null;
        try check(create_framebuffer(dev, &framebuffer_info, null, &framebuffer));
        errdefer destroyOne(device, c.PFN_vkDestroyFramebuffer, "vkDestroyFramebuffer", framebuffer);

        const byte_count: c.VkDeviceSize = @as(c.VkDeviceSize, width) * height * 4;
        var buffer_info = c.VkBufferCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = byte_count, .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE };
        var buffer: c.VkBuffer = null;
        try check(create_buffer(dev, &buffer_info, null, &buffer));
        errdefer destroyOne(device, c.PFN_vkDestroyBuffer, "vkDestroyBuffer", buffer);

        var buffer_reqs: c.VkMemoryRequirements = undefined;
        buffer_mem_reqs(dev, buffer, &buffer_reqs);
        const buffer_type = memory.typeIndex(device.memory_properties, buffer_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoSuitableMemory;
        var buffer_alloc = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = buffer_reqs.size, .memoryTypeIndex = buffer_type };
        var buffer_memory: c.VkDeviceMemory = null;
        try check(allocate_memory(dev, &buffer_alloc, null, &buffer_memory));
        errdefer freeOne(device, buffer_memory);
        try check(bind_buffer_memory(dev, buffer, buffer_memory, 0));

        var pool_info = c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = device.queue_family };
        var command_pool: c.VkCommandPool = null;
        try check(create_command_pool(dev, &pool_info, null, &command_pool));
        errdefer destroyOne(device, c.PFN_vkDestroyCommandPool, "vkDestroyCommandPool", command_pool);

        var command_buffer_info = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = command_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        var command_buffer: c.VkCommandBuffer = null;
        try check(allocate_command_buffers(dev, &command_buffer_info, &command_buffer));

        return .{
            .device = device,
            .width = width,
            .height = height,
            .byte_count = byte_count,
            .image = image,
            .image_memory = image_memory,
            .view = view,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .buffer = buffer,
            .buffer_memory = buffer_memory,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
        };
    }

    pub fn deinit(target: *Target) void {
        // The command pool owns the command buffer; destroying it frees both.
        destroyOne(target.device, c.PFN_vkDestroyCommandPool, "vkDestroyCommandPool", target.command_pool);
        freeOne(target.device, target.buffer_memory);
        destroyOne(target.device, c.PFN_vkDestroyBuffer, "vkDestroyBuffer", target.buffer);
        destroyOne(target.device, c.PFN_vkDestroyFramebuffer, "vkDestroyFramebuffer", target.framebuffer);
        destroyOne(target.device, c.PFN_vkDestroyRenderPass, "vkDestroyRenderPass", target.render_pass);
        destroyOne(target.device, c.PFN_vkDestroyImageView, "vkDestroyImageView", target.view);
        freeOne(target.device, target.image_memory);
        destroyOne(target.device, c.PFN_vkDestroyImage, "vkDestroyImage", target.image);
    }

    /// Begins the command buffer and the render pass, clearing to `clear`. The returned command
    /// buffer is where the caller records its draws before `endAndReadback`.
    pub fn beginPass(target: *Target, clear: [4]f32) Error!c.VkCommandBuffer {
        const begin_command_buffer = try req(target.device, c.PFN_vkBeginCommandBuffer, "vkBeginCommandBuffer");
        const cmd_begin_render_pass = try req(target.device, c.PFN_vkCmdBeginRenderPass, "vkCmdBeginRenderPass");

        var begin_info = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        try check(begin_command_buffer(target.command_buffer, &begin_info));

        var clear_value = c.VkClearValue{ .color = .{ .float32 = clear } };
        var render_pass_begin = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = target.render_pass,
            .framebuffer = target.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = target.width, .height = target.height } },
            .clearValueCount = 1,
            .pClearValues = &clear_value,
        };
        cmd_begin_render_pass(target.command_buffer, &render_pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
        return target.command_buffer;
    }

    /// Ends the render pass, copies the image into the readback buffer, submits, waits, and reads
    /// the frame back into memory owned by `gpa`.
    pub fn endAndReadback(target: *Target, gpa: std.mem.Allocator) Error!Frame {
        const dev = target.device.handle;
        const end_command_buffer = try req(target.device, c.PFN_vkEndCommandBuffer, "vkEndCommandBuffer");
        const cmd_end_render_pass = try req(target.device, c.PFN_vkCmdEndRenderPass, "vkCmdEndRenderPass");
        const cmd_copy_image_to_buffer = try req(target.device, c.PFN_vkCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer");
        const create_fence = try req(target.device, c.PFN_vkCreateFence, "vkCreateFence");
        const wait_for_fences = try req(target.device, c.PFN_vkWaitForFences, "vkWaitForFences");
        const queue_submit = try req(target.device, c.PFN_vkQueueSubmit, "vkQueueSubmit");
        const map_memory = try req(target.device, c.PFN_vkMapMemory, "vkMapMemory");
        const unmap_memory = try req(target.device, c.PFN_vkUnmapMemory, "vkUnmapMemory");

        cmd_end_render_pass(target.command_buffer);

        var region = c.VkBufferImageCopy{
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageExtent = .{ .width = target.width, .height = target.height, .depth = 1 },
        };
        cmd_copy_image_to_buffer(target.command_buffer, target.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, target.buffer, 1, &region);
        try check(end_command_buffer(target.command_buffer));

        var fence_info = c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        var fence: c.VkFence = null;
        try check(create_fence(dev, &fence_info, null, &fence));
        defer destroyOne(target.device, c.PFN_vkDestroyFence, "vkDestroyFence", fence);

        var submit = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &target.command_buffer };
        try check(queue_submit(target.device.graphics_queue, 1, &submit, fence));
        try check(wait_for_fences(dev, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));

        var mapped: ?*anyopaque = null;
        try check(map_memory(dev, target.buffer_memory, 0, target.byte_count, 0, &mapped));
        const source: [*]const u8 = @ptrCast(mapped.?);
        const pixels = try gpa.alloc(u8, @intCast(target.byte_count));
        @memcpy(pixels, source[0..@intCast(target.byte_count)]);
        unmap_memory(dev, target.buffer_memory);

        return .{ .width = target.width, .height = target.height, .pixels = pixels };
    }
};

/// Destroys a Vulkan object with the named destroy command, if it can be resolved. Used in
/// teardown paths, where a resolution failure has nowhere to go and cannot happen for a live
/// device anyway.
fn destroyOne(device: *device_mod.Device, comptime Fn: type, name: [*:0]const u8, handle: anytype) void {
    if (device.proc(Fn, name)) |destroy| destroy(device.handle, handle, null);
}

/// Frees a device allocation.
fn freeOne(device: *device_mod.Device, handle: c.VkDeviceMemory) void {
    if (device.proc(c.PFN_vkFreeMemory, "vkFreeMemory")) |free| free(device.handle, handle, null);
}

/// Renders a frame cleared to `clear` at `width`×`height` and reads it back — the scaffold with
/// no draws, and the proof the scaffold itself is sound.
pub fn renderClear(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32) Error!Frame {
    var target = try Target.init(device, width, height);
    defer target.deinit();
    _ = try target.beginPass(clear);
    return target.endAndReadback(gpa);
}

// --- Tests (a real GPU frame; strict on the lavapipe lane) ---

const testing = std.testing;
const env = @import("env.zig");
const instance_mod = @import("instance.zig");

test "a cleared frame reads back the exact clear colour, everywhere" {
    var instance = instance_mod.Instance.create("offscreen-test") catch return;
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
    try testing.expectEqual(magenta, frame.at(0, 0));
    try testing.expectEqual(magenta, frame.at(15, 7));
    try testing.expectEqual(magenta, frame.at(8, 4));
}
