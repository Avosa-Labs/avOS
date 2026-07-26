//! The Vulkan loader, resolved dynamically at runtime.
//!
//! Vulkan is a calling convention, not a link-time library: the loader is a platform
//! component that ships with the driver, and commands are reached through it rather than
//! linked. This opens the platform loader by name — no caller-supplied path, only the known
//! library names, most specific first — and resolves `vkGetInstanceProcAddr`, the one entry
//! point every other command is fetched through. A host without a loader (a headless CI
//! runner, a machine with no GPU driver) reports `LoaderNotFound` cleanly rather than
//! trapping, which is what lets the device degrade to the software path instead of crashing.

const std = @import("std");
const c = @import("bindings.zig").c;
const env = @import("env.zig");

pub const Error = error{ LoaderNotFound, MissingEntryPoint };

/// The platform Vulkan loader library names, tried in order. Only these fixed names are
/// opened — never a path from outside — so the boundary is the trust already in the driver.
pub const loader_names = [_][:0]const u8{
    "libvulkan.so.1", // Linux, the versioned soname
    "libvulkan.dylib", // macOS with a Vulkan SDK (MoltenVK ICD)
    "libvulkan.1.dylib",
    "vulkan-1.dll", // Windows
};

pub const Loader = struct {
    lib: std.DynLib,
    get_instance_proc_addr: c.PFN_vkGetInstanceProcAddr,

    /// Opens the first available platform loader and resolves its one bootstrap entry point.
    pub fn open() Error!Loader {
        for (loader_names) |name| {
            var lib = std.DynLib.open(name) catch continue;
            if (lib.lookup(c.PFN_vkGetInstanceProcAddr, "vkGetInstanceProcAddr")) |proc| {
                return .{ .lib = lib, .get_instance_proc_addr = proc };
            }
            lib.close();
        }
        return error.LoaderNotFound;
    }

    pub fn close(loader: *Loader) void {
        loader.lib.close();
    }

    /// Resolves a global command (one reached with a null instance): the small set available
    /// before an instance exists, such as `vkCreateInstance`. `Fn` is a Vulkan PFN typedef,
    /// itself an optional function pointer; the result is null when the command is absent.
    pub fn global(loader: Loader, comptime Fn: type, name: [*:0]const u8) Fn {
        const proc = loader.get_instance_proc_addr.?(null, name) orelse return null;
        return @as(@typeInfo(Fn).optional.child, @ptrCast(proc));
    }

    /// Resolves an instance-level command, dispatched for a created instance.
    pub fn instanceProc(loader: Loader, instance: c.VkInstance, comptime Fn: type, name: [*:0]const u8) Fn {
        const proc = loader.get_instance_proc_addr.?(instance, name) orelse return null;
        return @as(@typeInfo(Fn).optional.child, @ptrCast(proc));
    }
};

test "the loader names cover the target platforms and are non-empty" {
    try std.testing.expect(loader_names.len >= 3);
    for (loader_names) |name| try std.testing.expect(name.len > 0);
}

test "opening the loader yields a usable entry point or a clean absence" {
    // Deterministic on any host: where a loader is installed it resolves the bootstrap
    // command; where none is (headless CI) it reports LoaderNotFound rather than trapping.
    if (Loader.open()) |opened| {
        var loader = opened;
        defer loader.close();
        try std.testing.expect(loader.get_instance_proc_addr != null);
    } else |err| {
        if (env.deviceRequired()) return err; // the lavapipe lane guarantees a loader
        try std.testing.expectEqual(Error.LoaderNotFound, err);
    }
}
