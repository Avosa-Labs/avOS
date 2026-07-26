//! The logical device: a chosen GPU and a graphics queue, created through the instance.
//!
//! With an instance in hand, bringing up a device is enumerate, choose, create. This
//! enumerates the physical devices the instance sees, scores them by the rules in `select`,
//! and on the best one finds a graphics queue family and creates a logical device with a
//! single graphics queue. The logical device and its queue are the handles the rest of the
//! GPU path submits work through. Every choice made here is the pure logic in `select`, tested
//! without a GPU; this module is the runtime that feeds it real enumerations and issues the
//! Vulkan calls. A host with no usable GPU returns a typed error, so the caller falls back to
//! the software path deliberately.
//!
//! This builds the device and its queue. The surface and swapchain that carry frames to a
//! display are the presentation providers' concern, created against this device.

const std = @import("std");
const c = @import("bindings.zig").c;
const loader_mod = @import("loader.zig");
const instance_mod = @import("instance.zig");
const select = @import("select.zig");
const select_memory = @import("memory.zig");
const env = @import("env.zig");

pub const Error = error{
    NoPhysicalDevice,
    NoSuitableDevice,
    NoGraphicsQueue,
    DeviceCreationFailed,
    MissingEntryPoint,
    OutOfMemory,
};

pub const Device = struct {
    /// The physical device chosen, kept for queries the logical device does not answer.
    physical: c.VkPhysicalDevice,
    handle: c.VkDevice,
    graphics_queue: c.VkQueue,
    queue_family: u32,
    /// The chosen device's memory types and heaps, for choosing an allocation's memory type.
    memory_properties: c.VkPhysicalDeviceMemoryProperties,
    destroy: c.PFN_vkDestroyDevice,

    /// Enumerates, selects, and creates a logical device on the best GPU the instance sees.
    pub fn create(instance: *instance_mod.Instance, gpa: std.mem.Allocator) Error!Device {
        const loader = instance.loader;
        const handle = instance.handle;

        const enumerate = loader.instanceProc(handle, c.PFN_vkEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices") orelse return error.MissingEntryPoint;
        const get_properties = loader.instanceProc(handle, c.PFN_vkGetPhysicalDeviceProperties, "vkGetPhysicalDeviceProperties") orelse return error.MissingEntryPoint;
        const get_queue_families = loader.instanceProc(handle, c.PFN_vkGetPhysicalDeviceQueueFamilyProperties, "vkGetPhysicalDeviceQueueFamilyProperties") orelse return error.MissingEntryPoint;
        const get_memory_properties = loader.instanceProc(handle, c.PFN_vkGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties") orelse return error.MissingEntryPoint;
        const create_device = loader.instanceProc(handle, c.PFN_vkCreateDevice, "vkCreateDevice") orelse return error.MissingEntryPoint;
        const get_device_queue = loader.instanceProc(handle, c.PFN_vkGetDeviceQueue, "vkGetDeviceQueue") orelse return error.MissingEntryPoint;
        const destroy_device = loader.instanceProc(handle, c.PFN_vkDestroyDevice, "vkDestroyDevice") orelse return error.MissingEntryPoint;

        // Enumerate the physical devices (count, then fill).
        var count: u32 = 0;
        _ = enumerate(handle, &count, null);
        if (count == 0) return error.NoPhysicalDevice;
        const physical = try gpa.alloc(c.VkPhysicalDevice, count);
        defer gpa.free(physical);
        _ = enumerate(handle, &count, physical.ptr);

        // Score each and pick the best.
        const scores = try gpa.alloc(u64, count);
        defer gpa.free(scores);
        for (physical, 0..) |device, index| {
            var properties: c.VkPhysicalDeviceProperties = undefined;
            get_properties(device, &properties);
            scores[index] = select.scoreDevice(properties);
        }
        const chosen_index = select.pickDevice(scores) orelse return error.NoSuitableDevice;
        const chosen = physical[chosen_index];

        // Find a graphics queue family on the chosen device.
        var family_count: u32 = 0;
        get_queue_families(chosen, &family_count, null);
        const families = try gpa.alloc(c.VkQueueFamilyProperties, family_count);
        defer gpa.free(families);
        get_queue_families(chosen, &family_count, families.ptr);
        const family = select.graphicsQueueFamily(families) orelse return error.NoGraphicsQueue;

        // Create the logical device with one graphics queue.
        var priority: f32 = 1.0;
        var queue_info = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        var device_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
        };
        var logical: c.VkDevice = null;
        if (create_device(chosen, &device_info, null, &logical) != c.VK_SUCCESS) return error.DeviceCreationFailed;

        var queue: c.VkQueue = null;
        get_device_queue(logical, family, 0, &queue);

        var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        get_memory_properties(chosen, &memory_properties);

        return .{
            .physical = chosen,
            .handle = logical,
            .graphics_queue = queue,
            .queue_family = family,
            .memory_properties = memory_properties,
            .destroy = destroy_device,
        };
    }

    pub fn deinit(device: *Device) void {
        device.destroy.?(device.handle, null);
    }
};

test "a device is brought up where a GPU exists, or the reason is typed" {
    // Robust on any host: bring up an instance, then a device; on a GPU host it creates and
    // tears both down, on a headless one the first step already reports a typed absence.
    var instance = instance_mod.Instance.create("device-bring-up-test") catch |err| {
        if (env.deviceRequired()) return err; // the lavapipe lane must reach a device
        try std.testing.expect(err == error.LoaderNotFound or
            err == error.IncompatibleDriver or
            err == error.InstanceCreationFailed or
            err == error.MissingEntryPoint);
        return; // no instance here — nothing more to exercise
    };
    defer instance.deinit();

    if (Device.create(&instance, std.testing.allocator)) |created| {
        var device = created;
        try std.testing.expect(device.handle != null);
        try std.testing.expect(device.graphics_queue != null);
        try std.testing.expect(device.physical != null);
        // A real device reports at least one memory type to allocate from, and a host-visible
        // one exists (every implementation has one), so readback is always possible.
        try std.testing.expect(device.memory_properties.memoryTypeCount > 0);
        try std.testing.expect(select_memory.typeIndex(
            device.memory_properties,
            std.math.maxInt(u32),
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
        ) != null);
        device.deinit();
    } else |err| {
        if (env.deviceRequired()) return err; // lavapipe presents a device; creation must work
        try std.testing.expect(err == error.NoPhysicalDevice or
            err == error.NoSuitableDevice or
            err == error.NoGraphicsQueue or
            err == error.DeviceCreationFailed or
            err == error.MissingEntryPoint or
            err == error.OutOfMemory);
    }
}
