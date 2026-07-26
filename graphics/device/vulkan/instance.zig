//! The Vulkan instance: the adapter's entry into a driver, created through the loader.
//!
//! An instance is the connection to the Vulkan implementation — the object every later
//! command (enumerating GPUs, creating a surface and device) is reached through. Creating it
//! is the adapter's first real call, and it is where "is there a usable GPU stack here?" is
//! answered: the loader is opened, the instance version it supports is queried, and an
//! instance is created naming the engine and the API version the compositor targets. A host
//! without a loader or without a compatible driver returns a typed error, so the caller
//! chooses the software path deliberately rather than discovering a crash.
//!
//! This brings up the instance only. Physical-device selection, the logical device and its
//! queues, and the swapchain build on it in later steps.

const std = @import("std");
const c = @import("bindings.zig").c;
const loader_mod = @import("loader.zig");

pub const Error = loader_mod.Error || error{ IncompatibleDriver, InstanceCreationFailed };

/// The API version the compositor targets. 1.3 carries dynamic rendering, timeline
/// semaphores, and the synchronization the present path assumes.
pub fn targetApiVersion() u32 {
    return c.VK_MAKE_API_VERSION(0, 1, 3, 0);
}

pub const Instance = struct {
    loader: loader_mod.Loader,
    handle: c.VkInstance,
    /// The instance-level API version the loader reports it supports.
    api_version: u32,
    destroy: c.PFN_vkDestroyInstance,

    /// Opens the loader and creates an instance, or returns why it could not.
    pub fn create(application_name: [*:0]const u8) Error!Instance {
        var loader = try loader_mod.Loader.open();
        errdefer loader.close();

        // The instance version the loader supports; absent before 1.1, so default to 1.0.
        var supported: u32 = c.VK_API_VERSION_1_0;
        if (loader.global(c.PFN_vkEnumerateInstanceVersion, "vkEnumerateInstanceVersion")) |enumerate| {
            _ = enumerate(&supported);
        }

        const create_instance = loader.global(c.PFN_vkCreateInstance, "vkCreateInstance") orelse
            return error.MissingEntryPoint;

        const engine_version = c.VK_MAKE_API_VERSION(0, 1, 0, 0);
        var application = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = application_name,
            .applicationVersion = engine_version,
            .pEngineName = "compositor",
            .engineVersion = engine_version,
            .apiVersion = targetApiVersion(),
        };
        var info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &application,
        };

        var handle: c.VkInstance = null;
        const result = create_instance(&info, null, &handle);
        if (result != c.VK_SUCCESS) {
            return switch (result) {
                c.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
                else => error.InstanceCreationFailed,
            };
        }
        errdefer destroyHandle(loader, handle);

        const destroy = loader.instanceProc(handle, c.PFN_vkDestroyInstance, "vkDestroyInstance") orelse
            return error.MissingEntryPoint;

        return .{ .loader = loader, .handle = handle, .api_version = supported, .destroy = destroy };
    }

    pub fn deinit(instance: *Instance) void {
        instance.destroy.?(instance.handle, null);
        instance.loader.close();
    }
};

/// Destroys an instance handle during error unwinding, before the typed destroy is resolved.
fn destroyHandle(loader: loader_mod.Loader, handle: c.VkInstance) void {
    if (loader.instanceProc(handle, c.PFN_vkDestroyInstance, "vkDestroyInstance")) |destroy| {
        destroy(handle, null);
    }
}

test "an instance is created where a driver exists, or the reason is typed" {
    // Runs on any host: with a loader and a compatible driver it creates and tears down an
    // instance; without, it returns a typed error — never a crash, never a stub success.
    if (Instance.create("device-bring-up-test")) |created| {
        var instance = created;
        try std.testing.expect(instance.handle != null);
        instance.deinit();
    } else |err| {
        try std.testing.expect(err == error.LoaderNotFound or
            err == error.IncompatibleDriver or
            err == error.InstanceCreationFailed or
            err == error.MissingEntryPoint);
    }
}
