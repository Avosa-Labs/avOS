//! Swapchain planning: the image count and extent, computed from what the surface reports.
//!
//! Creating a swapchain needs numbers the surface constrains — how many images to hold, and
//! at what size — and getting them wrong is a validation error or a stretched frame. Those are
//! decisions over `VkSurfaceCapabilitiesKHR`, so they live here as pure functions, testable
//! without a surface: the count is one more than the minimum (so the compositor can work on
//! one image while another is presented) clamped to the maximum the surface allows, and the
//! extent is the surface's fixed size when it dictates one, or the desired size clamped to the
//! surface's bounds when it leaves the choice to the application.
//!
//! Nothing here calls Vulkan. It plans from capabilities already queried; the creation that
//! uses this plan needs a surface and a device.

const std = @import("std");
const c = @import("bindings.zig").c;

/// A surface whose extent is left to the application reports this sentinel as its current
/// width; otherwise `currentExtent` is the size the swapchain must use.
const undefined_extent: u32 = 0xFFFF_FFFF;

/// The number of images to request: one more than the minimum, so a frame can be composed
/// while another is presented, clamped to the maximum the surface allows (0 means no maximum).
pub fn imageCount(surface: c.VkSurfaceCapabilitiesKHR) u32 {
    var count = surface.minImageCount + 1;
    if (surface.maxImageCount != 0 and count > surface.maxImageCount) count = surface.maxImageCount;
    return count;
}

/// The extent to create the swapchain at: the surface's current extent when it fixes one,
/// otherwise the desired extent clamped to the surface's supported range.
pub fn extent(surface: c.VkSurfaceCapabilitiesKHR, desired_width: u32, desired_height: u32) c.VkExtent2D {
    if (surface.currentExtent.width != undefined_extent) return surface.currentExtent;
    return .{
        .width = std.math.clamp(desired_width, surface.minImageExtent.width, surface.maxImageExtent.width),
        .height = std.math.clamp(desired_height, surface.minImageExtent.height, surface.maxImageExtent.height),
    };
}

// --- Tests (pure, no GPU) ---

const testing = std.testing;

fn caps(min_images: u32, max_images: u32, current_w: u32, min_w: u32, max_w: u32) c.VkSurfaceCapabilitiesKHR {
    var value = std.mem.zeroes(c.VkSurfaceCapabilitiesKHR);
    value.minImageCount = min_images;
    value.maxImageCount = max_images;
    value.currentExtent = .{ .width = current_w, .height = current_w };
    value.minImageExtent = .{ .width = min_w, .height = min_w };
    value.maxImageExtent = .{ .width = max_w, .height = max_w };
    return value;
}

test "the image count is one above the minimum, clamped to the maximum" {
    try testing.expectEqual(@as(u32, 3), imageCount(caps(2, 0, 0, 0, 0))); // no maximum: min+1
    try testing.expectEqual(@as(u32, 3), imageCount(caps(2, 8, 0, 0, 0))); // min+1 under the cap
    try testing.expectEqual(@as(u32, 2), imageCount(caps(2, 2, 0, 0, 0))); // clamped down to the cap
}

test "a surface with a fixed extent dictates the size" {
    const value = extent(caps(2, 0, 1280, 0, 4096), 800, 600);
    try testing.expectEqual(@as(u32, 1280), value.width);
    try testing.expectEqual(@as(u32, 1280), value.height);
}

test "a surface that leaves the extent to us clamps the desired size to its bounds" {
    const undefined_current = undefined_extent;
    const bounded = caps(2, 0, undefined_current, 640, 1920);
    try testing.expectEqual(@as(u32, 800), extent(bounded, 800, 800).width); // within bounds: as asked
    try testing.expectEqual(@as(u32, 640), extent(bounded, 100, 100).width); // below the minimum
    try testing.expectEqual(@as(u32, 1920), extent(bounded, 4000, 4000).width); // above the maximum
}
