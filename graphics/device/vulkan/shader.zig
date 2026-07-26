//! A minimal graphics pipeline over an offscreen target: two stages, a fixed viewport, no vertex
//! input. It is the pipeline the frame renderers share — a triangle from the vertex index, or a
//! quad per push constant — differing only in their shaders, primitive topology, and whether they
//! carry a push constant. Vertices come from `gl_VertexIndex`, so there is no vertex buffer or
//! input state, and the viewport is baked to the target size. The pipeline is created against the
//! target's render pass and destroyed by `deinit`.

const std = @import("std");
const c = @import("bindings.zig").c;
const device_mod = @import("device.zig");
const offscreen = @import("offscreen.zig");

const Error = offscreen.Error;

pub const Pipeline = struct {
    handle: c.VkPipeline,
    layout: c.VkPipelineLayout,
    vertex_module: c.VkShaderModule,
    fragment_module: c.VkShaderModule,

    /// Builds the pipeline. `push_constant_size` is 0 for a pipeline with no push constant, else
    /// the size of a range covering the vertex and fragment stages from offset 0.
    pub fn init(
        device: *device_mod.Device,
        render_pass: c.VkRenderPass,
        width: u32,
        height: u32,
        vertex_spirv: []const u8,
        fragment_spirv: []const u8,
        push_constant_size: u32,
        topology: c.VkPrimitiveTopology,
        blend: bool,
        descriptor_set_layout: c.VkDescriptorSetLayout,
    ) Error!Pipeline {
        const dev = device.handle;
        const create_shader = try offscreen.req(device, c.PFN_vkCreateShaderModule, "vkCreateShaderModule");
        const create_layout = try offscreen.req(device, c.PFN_vkCreatePipelineLayout, "vkCreatePipelineLayout");
        const create_pipelines = try offscreen.req(device, c.PFN_vkCreateGraphicsPipelines, "vkCreateGraphicsPipelines");

        const vertex_module = try module(device, create_shader, vertex_spirv);
        errdefer destroyShader(device, vertex_module);
        const fragment_module = try module(device, create_shader, fragment_spirv);
        errdefer destroyShader(device, fragment_module);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vertex_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragment_module, .pName = "main" },
        };
        var vertex_input = c.VkPipelineVertexInputStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
        var input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = topology };
        var viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0, .maxDepth = 1 };
        var scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
        var viewport_state = c.VkPipelineViewportStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
        var rasterization = c.VkPipelineRasterizationStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = c.VK_POLYGON_MODE_FILL, .cullMode = c.VK_CULL_MODE_NONE, .frontFace = c.VK_FRONT_FACE_CLOCKWISE, .lineWidth = 1 };
        var multisample = c.VkPipelineMultisampleStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT };
        // Straight-alpha source-over when blending is on, so a fragment's coverage alpha mixes it
        // with the background; a plain overwrite otherwise.
        var blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .blendEnable = if (blend) c.VK_TRUE else c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        var color_blend = c.VkPipelineColorBlendStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &blend_attachment };

        var push_range = c.VkPushConstantRange{ .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, .offset = 0, .size = push_constant_size };
        var set_layout = descriptor_set_layout;
        var layout_info = c.VkPipelineLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        if (push_constant_size != 0) {
            layout_info.pushConstantRangeCount = 1;
            layout_info.pPushConstantRanges = &push_range;
        }
        if (set_layout != null) {
            layout_info.setLayoutCount = 1;
            layout_info.pSetLayouts = &set_layout;
        }
        var layout: c.VkPipelineLayout = null;
        try offscreen.check(create_layout(dev, &layout_info, null, &layout));
        errdefer destroyLayout(device, layout);

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
        var handle: c.VkPipeline = null;
        try offscreen.check(create_pipelines(dev, null, 1, &pipeline_info, null, &handle));

        return .{ .handle = handle, .layout = layout, .vertex_module = vertex_module, .fragment_module = fragment_module };
    }

    pub fn deinit(pipeline: *Pipeline, device: *device_mod.Device) void {
        if (device.proc(c.PFN_vkDestroyPipeline, "vkDestroyPipeline")) |destroy| destroy(device.handle, pipeline.handle, null);
        destroyLayout(device, pipeline.layout);
        destroyShader(device, pipeline.vertex_module);
        destroyShader(device, pipeline.fragment_module);
    }
};

fn module(device: *device_mod.Device, create: anytype, spirv: []const u8) Error!c.VkShaderModule {
    var info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spirv.len,
        .pCode = @ptrCast(@alignCast(spirv.ptr)),
    };
    var handle: c.VkShaderModule = null;
    try offscreen.check(create(device.handle, &info, null, &handle));
    return handle;
}

fn destroyShader(device: *device_mod.Device, handle: c.VkShaderModule) void {
    if (device.proc(c.PFN_vkDestroyShaderModule, "vkDestroyShaderModule")) |destroy| destroy(device.handle, handle, null);
}

fn destroyLayout(device: *device_mod.Device, handle: c.VkPipelineLayout) void {
    if (device.proc(c.PFN_vkDestroyPipelineLayout, "vkDestroyPipelineLayout")) |destroy| destroy(device.handle, handle, null);
}
