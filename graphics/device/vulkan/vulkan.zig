//! The Vulkan device adapter: the primary GPU backend, behind a Zig boundary.
//!
//! Vulkan is the primary GPU API (ADR 0004), and this is the adapter that speaks it — a Zig
//! surface over the pinned Vulkan headers, with the C types confined below this module. It is
//! built only where the pinned headers are present (see the build's built-when-present guard),
//! the same shape the WebAssembly runtime uses for its native library, so a checkout that has
//! not vendored the headers still builds everything else. What is here now is the bring-up
//! path: the dynamically resolved loader and the instance created through it. Physical-device
//! selection, the logical device and its queues, and the swapchain that carries the
//! compositor's frames build on this instance in later steps.
//!
//! The rest of the system never sees a Vulkan type: it sees this adapter and the presentation
//! interface. A host without a loader or a compatible driver gets a typed error here, and the
//! caller chooses the software path deliberately.

const std = @import("std");

pub const c = @import("bindings.zig").c;
pub const Loader = @import("loader.zig").Loader;
pub const Instance = @import("instance.zig").Instance;
pub const targetApiVersion = @import("instance.zig").targetApiVersion;
pub const Device = @import("device.zig").Device;
pub const select = @import("select.zig");
pub const capabilities = @import("capabilities.zig");

/// The major component of a packed Vulkan version (the header's VK_API_VERSION_MAJOR).
pub fn versionMajor(version: u32) u32 {
    return (version >> 22) & 0x7f;
}

/// The minor component of a packed Vulkan version.
pub fn versionMinor(version: u32) u32 {
    return (version >> 12) & 0x3ff;
}

/// The patch component of a packed Vulkan version.
pub fn versionPatch(version: u32) u32 {
    return version & 0xfff;
}

test {
    // Pull the loader and instance tests into this module's test run.
    std.testing.refAllDecls(@This());
    _ = @import("loader.zig");
    _ = @import("instance.zig");
    _ = @import("device.zig");
    _ = @import("select.zig");
    _ = @import("capabilities.zig");
}

test "the packed version helpers read the components the target encodes" {
    const v = targetApiVersion(); // 1.3.0
    try std.testing.expectEqual(@as(u32, 1), versionMajor(v));
    try std.testing.expectEqual(@as(u32, 3), versionMinor(v));
    try std.testing.expectEqual(@as(u32, 0), versionPatch(v));
}
