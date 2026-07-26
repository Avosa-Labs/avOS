//! What a swapchain surface attests to, read from the format chosen for it.
//!
//! The device seam reports capabilities — colour space, dynamic range, bit depth — so the
//! compositor can pick a colour path and know what the display will honour. On the GPU that
//! answer is not a guess: it is implied by the surface format `select` chose, which the driver
//! only offers where the panel supports it. This maps that chosen format to the capability
//! descriptor. A floating-point extended-linear surface attests to HDR at wide gamut and 16
//! bits; a 10-bit HDR10 surface to HDR at Rec.2020 and 10 bits; a Display-P3 surface to that
//! wider gamut; and an sRGB surface to the conservative 8-bit SDR baseline.
//!
//! This decides nothing about the GPU. It reads a chosen format and states what it means.

const std = @import("std");
const c = @import("bindings.zig").c;

pub const ColorSpace = enum { srgb, display_p3, rec2020 };

/// What a device presents at, matching the device seam's capability descriptor.
pub const Capabilities = struct {
    color_space: ColorSpace = .srgb,
    hdr: bool = false,
    bits_per_channel: u8 = 8,
};

/// The capabilities a chosen surface format attests to.
pub fn capabilitiesFor(format: c.VkSurfaceFormatKHR) Capabilities {
    const bits = bitsPerChannel(format.format);
    return switch (format.colorSpace) {
        // scRGB: floating-point, linear, extended range — HDR at wide gamut.
        c.VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT => .{ .color_space = .rec2020, .hdr = true, .bits_per_channel = bits },
        // HDR10 with the ST.2084 transfer — HDR at Rec.2020.
        c.VK_COLOR_SPACE_HDR10_ST2084_EXT => .{ .color_space = .rec2020, .hdr = true, .bits_per_channel = bits },
        // Display-P3: a wider gamut than sRGB, standard dynamic range.
        c.VK_COLOR_SPACE_DISPLAY_P3_NONLINEAR_EXT => .{ .color_space = .display_p3, .hdr = false, .bits_per_channel = bits },
        // sRGB and anything else: the conservative SDR baseline.
        else => .{ .color_space = .srgb, .hdr = false, .bits_per_channel = bits },
    };
}

/// The bits per colour channel a Vulkan format carries, for the formats the swapchain selects.
fn bitsPerChannel(format: c.VkFormat) u8 {
    return switch (format) {
        c.VK_FORMAT_R16G16B16A16_SFLOAT => 16,
        c.VK_FORMAT_A2B10G10R10_UNORM_PACK32, c.VK_FORMAT_A2R10G10B10_UNORM_PACK32 => 10,
        else => 8,
    };
}

// --- Tests ---

const testing = std.testing;

test "a float extended-linear surface attests to wide-gamut HDR at 16 bits" {
    const caps = capabilitiesFor(.{ .format = c.VK_FORMAT_R16G16B16A16_SFLOAT, .colorSpace = c.VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT });
    try testing.expectEqual(ColorSpace.rec2020, caps.color_space);
    try testing.expect(caps.hdr);
    try testing.expectEqual(@as(u8, 16), caps.bits_per_channel);
}

test "a 10-bit HDR10 surface attests to Rec.2020 HDR at 10 bits" {
    const caps = capabilitiesFor(.{ .format = c.VK_FORMAT_A2B10G10R10_UNORM_PACK32, .colorSpace = c.VK_COLOR_SPACE_HDR10_ST2084_EXT });
    try testing.expectEqual(ColorSpace.rec2020, caps.color_space);
    try testing.expect(caps.hdr);
    try testing.expectEqual(@as(u8, 10), caps.bits_per_channel);
}

test "a Display-P3 surface attests to the wider gamut but not HDR" {
    const caps = capabilitiesFor(.{ .format = c.VK_FORMAT_B8G8R8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_DISPLAY_P3_NONLINEAR_EXT });
    try testing.expectEqual(ColorSpace.display_p3, caps.color_space);
    try testing.expect(!caps.hdr);
}

test "an sRGB surface is the conservative 8-bit SDR baseline" {
    const caps = capabilitiesFor(.{ .format = c.VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR });
    try testing.expectEqual(ColorSpace.srgb, caps.color_space);
    try testing.expect(!caps.hdr);
    try testing.expectEqual(@as(u8, 8), caps.bits_per_channel);
}
