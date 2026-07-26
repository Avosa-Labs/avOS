//! Choosing a device memory type, as a pure function over what the device reports.
//!
//! Every GPU allocation names a memory type index, and the right one is a decision over the
//! device's `VkPhysicalDeviceMemoryProperties`: the allocation's requirements say which type
//! indices are permitted (a bitmask), and the use says which properties the memory must have —
//! device-local for a render target, host-visible and host-coherent for a buffer the CPU reads
//! back. This is that choice, kept pure so it is tested without a GPU. The runtime that queries
//! the properties and makes the allocation feeds this the real values.
//!
//! Nothing here calls Vulkan.

const std = @import("std");
const c = @import("bindings.zig").c;

/// The index of a memory type that both the allocation permits (`type_bits`, bit i set means
/// type i is allowed) and carries every property in `required`, or null if none qualifies. The
/// first qualifying type is returned, which is the device's own preference order.
pub fn typeIndex(properties: c.VkPhysicalDeviceMemoryProperties, type_bits: u32, required: c.VkMemoryPropertyFlags) ?u32 {
    var index: u32 = 0;
    while (index < properties.memoryTypeCount) : (index += 1) {
        const permitted = (type_bits & (@as(u32, 1) << @intCast(index))) != 0;
        const has_flags = (properties.memoryTypes[index].propertyFlags & required) == required;
        if (permitted and has_flags) return index;
    }
    return null;
}

// --- Tests (pure, no GPU) ---

const testing = std.testing;

fn memProps(types: []const c.VkMemoryPropertyFlags) c.VkPhysicalDeviceMemoryProperties {
    var props = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
    props.memoryTypeCount = @intCast(types.len);
    for (types, 0..) |flags, i| props.memoryTypes[i] = .{ .propertyFlags = flags, .heapIndex = 0 };
    return props;
}

test "the first type that is permitted and carries every required flag is chosen" {
    const device_local = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    const host_visible = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const props = memProps(&.{ device_local, host_visible, device_local | host_visible });

    // A device-local render target: type 0 qualifies and is first.
    try testing.expectEqual(@as(?u32, 0), typeIndex(props, 0b111, device_local));
    // A host-visible readback buffer: type 0 lacks the flags, type 1 has them.
    try testing.expectEqual(@as(?u32, 1), typeIndex(props, 0b111, host_visible));
}

test "a type the allocation does not permit is skipped even if its flags match" {
    const host_visible = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    const props = memProps(&.{ host_visible, host_visible });
    // type_bits forbids index 0, so index 1 is chosen.
    try testing.expectEqual(@as(?u32, 1), typeIndex(props, 0b10, host_visible));
}

test "no qualifying type gives null" {
    const props = memProps(&.{c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT});
    try testing.expectEqual(@as(?u32, null), typeIndex(props, 0b1, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT));
    try testing.expectEqual(@as(?u32, null), typeIndex(props, 0b0, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)); // none permitted
}
