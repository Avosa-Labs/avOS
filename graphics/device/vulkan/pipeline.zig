//! A graphics pipeline drawing real geometry into an offscreen frame, read back for a gate.
//!
//! Clearing an image (see `offscreen`) proves the submission spine; this proves the part that
//! actually rasterises. It builds a minimal graphics pipeline — a vertex stage that emits a
//! triangle from the vertex index and a fragment stage that writes a solid colour — and draws
//! it into the same kind of offscreen colour image, then reads the result back. The triangle
//! covers the middle of the frame and leaves the corners on the cleared background, so the
//! readback distinguishes rasterised geometry from the clear: the centre is the triangle's
//! colour, a corner is the clear colour. That is a real GPU draw, pixel-conformant, headless.
//!
//! The shaders are compiled to SPIR-V ahead of time and embedded, so no shader compiler is in
//! the build. Every Vulkan object is destroyed before the function returns, on success or error.

const std = @import("std");
const c = @import("bindings.zig").c;
const device_mod = @import("device.zig");
const memory = @import("memory.zig");
const offscreen = @import("offscreen.zig");

const Error = offscreen.Error;
pub const Frame = offscreen.Frame;
pub const Rgba = offscreen.Rgba;

// The pre-compiled shaders, 4-byte aligned so their bytes can be read as SPIR-V words.
const vertex_spirv align(4) = @embedFile("shaders/triangle.vert.spv").*;
const fragment_spirv align(4) = @embedFile("shaders/triangle.frag.spv").*;

fn shaderModule(device: *device_mod.Device, create: anytype, spirv: []const u8) Error!c.VkShaderModule {
    var info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spirv.len,
        .pCode = @ptrCast(@alignCast(spirv.ptr)),
    };
    var module: c.VkShaderModule = null;
    try offscreen.check(create(device.handle, &info, null, &module));
    return module;
}

/// Draws the embedded triangle into a `width`×`height` frame cleared to `clear`, and reads it
/// back. The returned frame's pixels are owned by `gpa`.
pub fn renderTriangle(device: *device_mod.Device, gpa: std.mem.Allocator, width: u32, height: u32, clear: [4]f32) Error!Frame {
    const create_image = try offscreen.req(device, c.PFN_vkCreateImage, "vkCreateImage");
    const destroy_image = try offscreen.req(device, c.PFN_vkDestroyImage, "vkDestroyImage");
    const image_mem_reqs = try offscreen.req(device, c.PFN_vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
    const allocate_memory = try offscreen.req(device, c.PFN_vkAllocateMemory, "vkAllocateMemory");
    const free_memory = try offscreen.req(device, c.PFN_vkFreeMemory, "vkFreeMemory");
    const bind_image_memory = try offscreen.req(device, c.PFN_vkBindImageMemory, "vkBindImageMemory");
    const create_view = try offscreen.req(device, c.PFN_vkCreateImageView, "vkCreateImageView");
    const destroy_view = try offscreen.req(device, c.PFN_vkDestroyImageView, "vkDestroyImageView");
    const create_render_pass = try offscreen.req(device, c.PFN_vkCreateRenderPass, "vkCreateRenderPass");
    const destroy_render_pass = try offscreen.req(device, c.PFN_vkDestroyRenderPass, "vkDestroyRenderPass");
    const create_framebuffer = try offscreen.req(device, c.PFN_vkCreateFramebuffer, "vkCreateFramebuffer");
    const destroy_framebuffer = try offscreen.req(device, c.PFN_vkDestroyFramebuffer, "vkDestroyFramebuffer");
    const create_buffer = try offscreen.req(device, c.PFN_vkCreateBuffer, "vkCreateBuffer");
    const destroy_buffer = try offscreen.req(device, c.PFN_vkDestroyBuffer, "vkDestroyBuffer");
    const buffer_mem_reqs = try offscreen.req(device, c.PFN_vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
    const bind_buffer_memory = try offscreen.req(device, c.PFN_vkBindBufferMemory, "vkBindBufferMemory");
    const create_shader = try offscreen.req(device, c.PFN_vkCreateShaderModule, "vkCreateShaderModule");
    const destroy_shader = try offscreen.req(device, c.PFN_vkDestroyShaderModule, "vkDestroyShaderModule");
    const create_layout = try offscreen.req(device, c.PFN_vkCreatePipelineLayout, "vkCreatePipelineLayout");
    const destroy_layout = try offscreen.req(device, c.PFN_vkDestroyPipelineLayout, "vkDestroyPipelineLayout");
    const create_pipelines = try offscreen.req(device, c.PFN_vkCreateGraphicsPipelines, "vkCreateGraphicsPipelines");
    const destroy_pipeline = try offscreen.req(device, c.PFN_vkDestroyPipeline, "vkDestroyPipeline");
    const create_command_pool = try offscreen.req(device, c.PFN_vkCreateCommandPool, "vkCreateCommandPool");
    const destroy_command_pool = try offscreen.req(device, c.PFN_vkDestroyCommandPool, "vkDestroyCommandPool");
    const allocate_command_buffers = try offscreen.req(device, c.PFN_vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
    const begin_command_buffer = try offscreen.req(device, c.PFN_vkBeginCommandBuffer, "vkBeginCommandBuffer");
    const end_command_buffer = try offscreen.req(device, c.PFN_vkEndCommandBuffer, "vkEndCommandBuffer");
    const cmd_begin_render_pass = try offscreen.req(device, c.PFN_vkCmdBeginRenderPass, "vkCmdBeginRenderPass");
    const cmd_end_render_pass = try offscreen.req(device, c.PFN_vkCmdEndRenderPass, "vkCmdEndRenderPass");
    const cmd_bind_pipeline = try offscreen.req(device, c.PFN_vkCmdBindPipeline, "vkCmdBindPipeline");
    const cmd_draw = try offscreen.req(device, c.PFN_vkCmdDraw, "vkCmdDraw");
    const cmd_copy_image_to_buffer = try offscreen.req(device, c.PFN_vkCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer");
    const create_fence = try offscreen.req(device, c.PFN_vkCreateFence, "vkCreateFence");
    const destroy_fence = try offscreen.req(device, c.PFN_vkDestroyFence, "vkDestroyFence");
    const wait_for_fences = try offscreen.req(device, c.PFN_vkWaitForFences, "vkWaitForFences");
    const queue_submit = try offscreen.req(device, c.PFN_vkQueueSubmit, "vkQueueSubmit");
    const map_memory = try offscreen.req(device, c.PFN_vkMapMemory, "vkMapMemory");
    const unmap_memory = try offscreen.req(device, c.PFN_vkUnmapMemory, "vkUnmapMemory");

    const dev = device.handle;

    // Colour image + device-local memory + view (as in the clear path).
    var image_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = offscreen.format,
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
    try offscreen.check(create_image(dev, &image_info, null, &image));
    defer destroy_image(dev, image, null);

    var image_reqs: c.VkMemoryRequirements = undefined;
    image_mem_reqs(dev, image, &image_reqs);
    const image_type = memory.typeIndex(device.memory_properties, image_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoSuitableMemory;
    var image_alloc = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = image_reqs.size, .memoryTypeIndex = image_type };
    var image_memory: c.VkDeviceMemory = null;
    try offscreen.check(allocate_memory(dev, &image_alloc, null, &image_memory));
    defer free_memory(dev, image_memory, null);
    try offscreen.check(bind_image_memory(dev, image, image_memory, 0));

    var view_info = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = offscreen.format,
        .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
    };
    var view: c.VkImageView = null;
    try offscreen.check(create_view(dev, &view_info, null, &view));
    defer destroy_view(dev, view, null);

    // Render pass: clear, draw, leave ready to copy out.
    var attachment = c.VkAttachmentDescription{
        .format = offscreen.format,
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
    var render_pass_info = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
    };
    var render_pass: c.VkRenderPass = null;
    try offscreen.check(create_render_pass(dev, &render_pass_info, null, &render_pass));
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
    try offscreen.check(create_framebuffer(dev, &framebuffer_info, null, &framebuffer));
    defer destroy_framebuffer(dev, framebuffer, null);

    // The graphics pipeline: two stages, a triangle list, fixed viewport, no vertex input.
    const vertex_module = try shaderModule(device, create_shader, &vertex_spirv);
    defer destroy_shader(dev, vertex_module, null);
    const fragment_module = try shaderModule(device, create_shader, &fragment_spirv);
    defer destroy_shader(dev, fragment_module, null);

    var stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vertex_module, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragment_module, .pName = "main" },
    };
    var vertex_input = c.VkPipelineVertexInputStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    var input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    var viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0, .maxDepth = 1 };
    var scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
    var viewport_state = c.VkPipelineViewportStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
    var rasterization = c.VkPipelineRasterizationStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
        .lineWidth = 1,
    };
    var multisample = c.VkPipelineMultisampleStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT };
    var blend_attachment = c.VkPipelineColorBlendAttachmentState{
        .blendEnable = c.VK_FALSE,
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    var color_blend = c.VkPipelineColorBlendStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &blend_attachment };

    var layout_info = c.VkPipelineLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    var layout: c.VkPipelineLayout = null;
    try offscreen.check(create_layout(dev, &layout_info, null, &layout));
    defer destroy_layout(dev, layout, null);

    var pipeline_info = c.VkGraphicsPipelineCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pColorBlendState = &color_blend,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
    };
    var pipeline: c.VkPipeline = null;
    try offscreen.check(create_pipelines(dev, null, 1, &pipeline_info, null, &pipeline));
    defer destroy_pipeline(dev, pipeline, null);

    // Readback buffer.
    const byte_count: c.VkDeviceSize = @as(c.VkDeviceSize, width) * height * 4;
    var buffer_info = c.VkBufferCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = byte_count, .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE };
    var buffer: c.VkBuffer = null;
    try offscreen.check(create_buffer(dev, &buffer_info, null, &buffer));
    defer destroy_buffer(dev, buffer, null);

    var buffer_reqs: c.VkMemoryRequirements = undefined;
    buffer_mem_reqs(dev, buffer, &buffer_reqs);
    const buffer_type = memory.typeIndex(device.memory_properties, buffer_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoSuitableMemory;
    var buffer_alloc = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = buffer_reqs.size, .memoryTypeIndex = buffer_type };
    var buffer_memory: c.VkDeviceMemory = null;
    try offscreen.check(allocate_memory(dev, &buffer_alloc, null, &buffer_memory));
    defer free_memory(dev, buffer_memory, null);
    try offscreen.check(bind_buffer_memory(dev, buffer, buffer_memory, 0));

    // Record: clear, bind the pipeline, draw the triangle, copy out.
    var pool_info = c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = device.queue_family };
    var command_pool: c.VkCommandPool = null;
    try offscreen.check(create_command_pool(dev, &pool_info, null, &command_pool));
    defer destroy_command_pool(dev, command_pool, null);

    var command_buffer_info = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = command_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    var command_buffer: c.VkCommandBuffer = null;
    try offscreen.check(allocate_command_buffers(dev, &command_buffer_info, &command_buffer));

    var begin_info = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    try offscreen.check(begin_command_buffer(command_buffer, &begin_info));

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
    cmd_bind_pipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    cmd_draw(command_buffer, 3, 1, 0, 0);
    cmd_end_render_pass(command_buffer);

    var region = c.VkBufferImageCopy{
        .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
    cmd_copy_image_to_buffer(command_buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    try offscreen.check(end_command_buffer(command_buffer));

    var fence_info = c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    var fence: c.VkFence = null;
    try offscreen.check(create_fence(dev, &fence_info, null, &fence));
    defer destroy_fence(dev, fence, null);

    var submit = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command_buffer };
    try offscreen.check(queue_submit(device.graphics_queue, 1, &submit, fence));
    try offscreen.check(wait_for_fences(dev, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));

    var mapped: ?*anyopaque = null;
    try offscreen.check(map_memory(dev, buffer_memory, 0, byte_count, 0, &mapped));
    const source: [*]const u8 = @ptrCast(mapped.?);
    const pixels = try gpa.alloc(u8, @intCast(byte_count));
    @memcpy(pixels, source[0..@intCast(byte_count)]);
    unmap_memory(dev, buffer_memory);

    return .{ .width = width, .height = height, .pixels = pixels };
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

    // Clear to black, draw the green triangle.
    var frame = try renderTriangle(&device, testing.allocator, 64, 64, .{ 0.0, 0.0, 0.0, 1.0 });
    defer frame.deinit(testing.allocator);

    const green = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const black = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    try testing.expectEqual(green, frame.at(32, 40)); // inside the triangle (lower centre)
    try testing.expectEqual(black, frame.at(1, 1)); // top-left corner: outside the triangle
    try testing.expectEqual(black, frame.at(62, 1)); // top-right corner: outside
}
