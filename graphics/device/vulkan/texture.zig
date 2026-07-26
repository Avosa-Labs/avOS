//! A sampled coverage texture: a single-channel image the GPU reads to draw glyphs and masks.
//!
//! Text and other alpha masks reach the GPU as coverage — one byte per texel, how much ink is at
//! that pixel — and the renderer samples it while drawing a quad. Getting the bytes onto the GPU
//! is the work here: an R8 image is allocated device-local, the coverage is copied into a
//! host-visible staging buffer, and a command buffer transitions the image, copies the buffer
//! into it, and transitions it again to shader-read layout. A view and a sampler complete the
//! texture the pipeline binds. Nearest sampling keeps a texel's value exact, so a gate can assert
//! it. Every Vulkan object is destroyed by `deinit`; the staging buffer is gone before `upload`
//! returns.

const std = @import("std");
const c = @import("bindings.zig").c;
const device_mod = @import("device.zig");
const memory = @import("memory.zig");
const offscreen = @import("offscreen.zig");

const Error = offscreen.Error;

pub const Texture = struct {
    image: c.VkImage,
    image_memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    width: u32,
    height: u32,

    /// Uploads `coverage` (one byte per texel, row-major, length width*height) into a sampled R8
    /// image and returns the texture. The device must be able to submit on its graphics queue.
    pub fn upload(device: *device_mod.Device, width: u32, height: u32, coverage: []const u8) Error!Texture {
        std.debug.assert(coverage.len == @as(usize, width) * height);
        const dev = device.handle;

        const create_image = try offscreen.req(device, c.PFN_vkCreateImage, "vkCreateImage");
        const image_mem_reqs = try offscreen.req(device, c.PFN_vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
        const allocate_memory = try offscreen.req(device, c.PFN_vkAllocateMemory, "vkAllocateMemory");
        const free_memory = try offscreen.req(device, c.PFN_vkFreeMemory, "vkFreeMemory");
        const bind_image_memory = try offscreen.req(device, c.PFN_vkBindImageMemory, "vkBindImageMemory");
        const create_buffer = try offscreen.req(device, c.PFN_vkCreateBuffer, "vkCreateBuffer");
        const destroy_buffer = try offscreen.req(device, c.PFN_vkDestroyBuffer, "vkDestroyBuffer");
        const buffer_mem_reqs = try offscreen.req(device, c.PFN_vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
        const bind_buffer_memory = try offscreen.req(device, c.PFN_vkBindBufferMemory, "vkBindBufferMemory");
        const map_memory = try offscreen.req(device, c.PFN_vkMapMemory, "vkMapMemory");
        const unmap_memory = try offscreen.req(device, c.PFN_vkUnmapMemory, "vkUnmapMemory");
        const create_command_pool = try offscreen.req(device, c.PFN_vkCreateCommandPool, "vkCreateCommandPool");
        const destroy_command_pool = try offscreen.req(device, c.PFN_vkDestroyCommandPool, "vkDestroyCommandPool");
        const allocate_command_buffers = try offscreen.req(device, c.PFN_vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
        const begin_command_buffer = try offscreen.req(device, c.PFN_vkBeginCommandBuffer, "vkBeginCommandBuffer");
        const end_command_buffer = try offscreen.req(device, c.PFN_vkEndCommandBuffer, "vkEndCommandBuffer");
        const cmd_pipeline_barrier = try offscreen.req(device, c.PFN_vkCmdPipelineBarrier, "vkCmdPipelineBarrier");
        const cmd_copy_buffer_to_image = try offscreen.req(device, c.PFN_vkCmdCopyBufferToImage, "vkCmdCopyBufferToImage");
        const create_fence = try offscreen.req(device, c.PFN_vkCreateFence, "vkCreateFence");
        const destroy_fence = try offscreen.req(device, c.PFN_vkDestroyFence, "vkDestroyFence");
        const wait_for_fences = try offscreen.req(device, c.PFN_vkWaitForFences, "vkWaitForFences");
        const queue_submit = try offscreen.req(device, c.PFN_vkQueueSubmit, "vkQueueSubmit");
        const create_view = try offscreen.req(device, c.PFN_vkCreateImageView, "vkCreateImageView");
        const create_sampler = try offscreen.req(device, c.PFN_vkCreateSampler, "vkCreateSampler");

        // The sampled image.
        var image_info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = c.VK_FORMAT_R8_UNORM,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: c.VkImage = null;
        try offscreen.check(create_image(dev, &image_info, null, &image));
        errdefer destroyImage(device, image);

        var image_reqs: c.VkMemoryRequirements = undefined;
        image_mem_reqs(dev, image, &image_reqs);
        const image_type = memory.typeIndex(device.memory_properties, image_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoSuitableMemory;
        var image_alloc = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = image_reqs.size, .memoryTypeIndex = image_type };
        var image_memory: c.VkDeviceMemory = null;
        try offscreen.check(allocate_memory(dev, &image_alloc, null, &image_memory));
        errdefer freeMemory(device, image_memory);
        try offscreen.check(bind_image_memory(dev, image, image_memory, 0));

        // Staging buffer holding the coverage, host-visible.
        const byte_count: c.VkDeviceSize = @intCast(coverage.len);
        var buffer_info = c.VkBufferCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = byte_count, .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE };
        var staging: c.VkBuffer = null;
        try offscreen.check(create_buffer(dev, &buffer_info, null, &staging));
        defer destroy_buffer(dev, staging, null);

        var staging_reqs: c.VkMemoryRequirements = undefined;
        buffer_mem_reqs(dev, staging, &staging_reqs);
        const staging_type = memory.typeIndex(device.memory_properties, staging_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoSuitableMemory;
        var staging_alloc = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = staging_reqs.size, .memoryTypeIndex = staging_type };
        var staging_memory: c.VkDeviceMemory = null;
        try offscreen.check(allocate_memory(dev, &staging_alloc, null, &staging_memory));
        defer free_memory(dev, staging_memory, null);
        try offscreen.check(bind_buffer_memory(dev, staging, staging_memory, 0));

        var mapped: ?*anyopaque = null;
        try offscreen.check(map_memory(dev, staging_memory, 0, byte_count, 0, &mapped));
        const dst: [*]u8 = @ptrCast(mapped.?);
        @memcpy(dst[0..coverage.len], coverage);
        unmap_memory(dev, staging_memory);

        // Transition, copy, transition, on a one-shot command buffer.
        var pool_info = c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = device.queue_family };
        var command_pool: c.VkCommandPool = null;
        try offscreen.check(create_command_pool(dev, &pool_info, null, &command_pool));
        defer destroy_command_pool(dev, command_pool, null);

        var command_buffer_info = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = command_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        var command_buffer: c.VkCommandBuffer = null;
        try offscreen.check(allocate_command_buffers(dev, &command_buffer_info, &command_buffer));

        var begin_info = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        try offscreen.check(begin_command_buffer(command_buffer, &begin_info));

        const subresource = c.VkImageSubresourceRange{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        var to_transfer = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = subresource,
        };
        cmd_pipeline_barrier(command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_transfer);

        var region = c.VkBufferImageCopy{
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };
        cmd_copy_buffer_to_image(command_buffer, staging, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        var to_shader = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = subresource,
        };
        cmd_pipeline_barrier(command_buffer, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &to_shader);
        try offscreen.check(end_command_buffer(command_buffer));

        var fence_info = c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        var fence: c.VkFence = null;
        try offscreen.check(create_fence(dev, &fence_info, null, &fence));
        defer destroy_fence(dev, fence, null);
        var submit = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command_buffer };
        try offscreen.check(queue_submit(device.graphics_queue, 1, &submit, fence));
        try offscreen.check(wait_for_fences(dev, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));

        // View and a nearest sampler (exact texel values).
        var view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_R8_UNORM,
            .subresourceRange = subresource,
        };
        var view: c.VkImageView = null;
        try offscreen.check(create_view(dev, &view_info, null, &view));
        errdefer destroyView(device, view);

        var sampler_info = c.VkSamplerCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = c.VK_FILTER_NEAREST,
            .minFilter = c.VK_FILTER_NEAREST,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        };
        var sampler: c.VkSampler = null;
        try offscreen.check(create_sampler(dev, &sampler_info, null, &sampler));

        return .{ .image = image, .image_memory = image_memory, .view = view, .sampler = sampler, .width = width, .height = height };
    }

    pub fn deinit(texture: *Texture, device: *device_mod.Device) void {
        if (device.proc(c.PFN_vkDestroySampler, "vkDestroySampler")) |destroy| destroy(device.handle, texture.sampler, null);
        destroyView(device, texture.view);
        freeMemory(device, texture.image_memory);
        destroyImage(device, texture.image);
    }
};

fn destroyImage(device: *device_mod.Device, image: c.VkImage) void {
    if (device.proc(c.PFN_vkDestroyImage, "vkDestroyImage")) |destroy| destroy(device.handle, image, null);
}

fn destroyView(device: *device_mod.Device, view: c.VkImageView) void {
    if (device.proc(c.PFN_vkDestroyImageView, "vkDestroyImageView")) |destroy| destroy(device.handle, view, null);
}

fn freeMemory(device: *device_mod.Device, handle: c.VkDeviceMemory) void {
    if (device.proc(c.PFN_vkFreeMemory, "vkFreeMemory")) |free| free(device.handle, handle, null);
}
