//! The device and swapchain selection rules, as pure functions over what a driver reports.
//!
//! Bringing up a GPU is a sequence of choices — which physical device, which queue family,
//! which surface format and present mode — and each is a decision over a list the driver
//! hands back. Keeping those decisions here, as pure functions, is what makes them testable
//! without a GPU: the enumeration needs a device, but the choice made from an enumeration does
//! not. The rules encode what the compositor needs: a device that can render, a graphics
//! queue, a wide-gamut floating-point surface where one exists (the colour pipeline is
//! linear-light and HDR-capable), and a mailbox present mode for the 120 Hz path with FIFO as
//! the guaranteed fallback.
//!
//! Nothing here calls Vulkan. It decides from values already fetched.

const std = @import("std");
const c = @import("bindings.zig").c;

/// The index of the first queue family that can do graphics, or null if none can.
pub fn graphicsQueueFamily(families: []const c.VkQueueFamilyProperties) ?u32 {
    for (families, 0..) |family, index| {
        if (family.queueCount == 0) continue;
        if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) return @intCast(index);
    }
    return null;
}

/// A device's fitness for the compositor: a discrete GPU is preferred over an integrated one,
/// which is preferred over anything else, with the maximum 2D image dimension breaking ties in
/// favour of the more capable part. Zero means unusable.
pub fn scoreDevice(properties: c.VkPhysicalDeviceProperties) u64 {
    const class: u64 = switch (properties.deviceType) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 3,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1,
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => 1,
        else => 0,
    };
    if (class == 0) return 0;
    return class * (1 << 32) + properties.limits.maxImageDimension2D;
}

/// The index of the highest-scoring device, or null if every device scores zero (none usable).
pub fn pickDevice(scores: []const u64) ?usize {
    var best: ?usize = null;
    var best_score: u64 = 0;
    for (scores, 0..) |score, index| {
        if (score > best_score) {
            best_score = score;
            best = index;
        }
    }
    return best;
}

/// The surface format to render into, chosen from what the surface supports. A wide-gamut
/// floating-point format in an extended-linear colour space is preferred — it carries the
/// linear-light HDR pipeline without a round trip through 8-bit sRGB — then a 10-bit HDR10
/// format, then 8-bit sRGB, and finally whatever the surface offers first.
pub fn surfaceFormat(formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    // Preference order, most capable first.
    const preferred = [_]c.VkSurfaceFormatKHR{
        .{ .format = c.VK_FORMAT_R16G16B16A16_SFLOAT, .colorSpace = c.VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT },
        .{ .format = c.VK_FORMAT_A2B10G10R10_UNORM_PACK32, .colorSpace = c.VK_COLOR_SPACE_HDR10_ST2084_EXT },
        .{ .format = c.VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = c.VK_FORMAT_R8G8B8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    };
    for (preferred) |want| {
        for (formats) |have| {
            if (have.format == want.format and have.colorSpace == want.colorSpace) return have;
        }
    }
    return formats[0];
}

/// The present mode: mailbox for a low-latency, tear-free 120 Hz path, falling back to FIFO,
/// which every implementation must support.
pub fn presentMode(modes: []const c.VkPresentModeKHR) c.VkPresentModeKHR {
    for (modes) |mode| {
        if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) return c.VK_PRESENT_MODE_MAILBOX_KHR;
    }
    return c.VK_PRESENT_MODE_FIFO_KHR; // the guaranteed fallback
}

// --- Tests (pure, no GPU) ---

const testing = std.testing;

test "the first graphics-capable queue family is chosen" {
    const families = [_]c.VkQueueFamilyProperties{
        .{ .queueFlags = c.VK_QUEUE_TRANSFER_BIT, .queueCount = 1, .timestampValidBits = 0, .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 } },
        .{ .queueFlags = c.VK_QUEUE_GRAPHICS_BIT | c.VK_QUEUE_COMPUTE_BIT, .queueCount = 2, .timestampValidBits = 0, .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 } },
    };
    try testing.expectEqual(@as(?u32, 1), graphicsQueueFamily(&families));
}

test "a family with no queues, or no graphics bit, is not chosen" {
    const none = [_]c.VkQueueFamilyProperties{
        .{ .queueFlags = c.VK_QUEUE_GRAPHICS_BIT, .queueCount = 0, .timestampValidBits = 0, .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 } },
        .{ .queueFlags = c.VK_QUEUE_COMPUTE_BIT, .queueCount = 4, .timestampValidBits = 0, .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 } },
    };
    try testing.expectEqual(@as(?u32, null), graphicsQueueFamily(&none));
}

fn deviceProps(kind: c.VkPhysicalDeviceType, max_dim: u32) c.VkPhysicalDeviceProperties {
    var props = std.mem.zeroes(c.VkPhysicalDeviceProperties);
    props.deviceType = kind;
    props.limits.maxImageDimension2D = max_dim;
    return props;
}

test "a discrete GPU outscores an integrated one, and ties break on capability" {
    const discrete = scoreDevice(deviceProps(c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU, 8192));
    const integrated = scoreDevice(deviceProps(c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU, 16384));
    const other = scoreDevice(deviceProps(c.VK_PHYSICAL_DEVICE_TYPE_OTHER, 8192));
    try testing.expect(discrete > integrated);
    try testing.expect(integrated > other);
    try testing.expectEqual(@as(u64, 0), other); // unusable

    const big = scoreDevice(deviceProps(c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU, 16384));
    try testing.expect(big > discrete); // same class, more capable
}

test "the best device is the highest score, and all-zero picks nothing" {
    try testing.expectEqual(@as(?usize, 2), pickDevice(&[_]u64{ 10, 40, 90, 5 }));
    try testing.expectEqual(@as(?usize, null), pickDevice(&[_]u64{ 0, 0, 0 }));
    try testing.expectEqual(@as(?usize, null), pickDevice(&[_]u64{}));
}

test "the wide-gamut float format wins when offered, sRGB is the fallback" {
    const with_float = [_]c.VkSurfaceFormatKHR{
        .{ .format = c.VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = c.VK_FORMAT_R16G16B16A16_SFLOAT, .colorSpace = c.VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT },
    };
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_R16G16B16A16_SFLOAT), surfaceFormat(&with_float).format);

    const only_srgb = [_]c.VkSurfaceFormatKHR{
        .{ .format = c.VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    };
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_B8G8R8A8_SRGB), surfaceFormat(&only_srgb).format);
}

test "mailbox is chosen when available, otherwise the guaranteed FIFO" {
    const with_mailbox = [_]c.VkPresentModeKHR{ c.VK_PRESENT_MODE_IMMEDIATE_KHR, c.VK_PRESENT_MODE_MAILBOX_KHR, c.VK_PRESENT_MODE_FIFO_KHR };
    try testing.expectEqual(@as(c.VkPresentModeKHR, c.VK_PRESENT_MODE_MAILBOX_KHR), presentMode(&with_mailbox));

    const no_mailbox = [_]c.VkPresentModeKHR{ c.VK_PRESENT_MODE_IMMEDIATE_KHR, c.VK_PRESENT_MODE_FIFO_KHR };
    try testing.expectEqual(@as(c.VkPresentModeKHR, c.VK_PRESENT_MODE_FIFO_KHR), presentMode(&no_mailbox));
}
