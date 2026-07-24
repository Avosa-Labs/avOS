//! The GPU backend: the display list encoded into an instance buffer a GPU draws in one pass.
//!
//! The whole render layer is built around a backend-agnostic display list — an ordered list of paint
//! commands. The software rasterizer is one backend, the reference: it walks the list and writes pixels
//! on the CPU, correct on any host with no GPU. This module is the other backend. It encodes the same
//! list into a flat buffer of quad *instances*, each carrying its rectangle, corner radius, colours, and
//! a kind tag. A GPU renders the whole buffer with a single instanced draw call whose fragment shader
//! evaluates the gradient and the superellipse coverage per pixel — the same squircle and gradients the
//! CPU path produces, but shaded in parallel on the GPU. Crucially, nothing above changes: both backends
//! consume the identical display list, so a frame is defined once and either path renders it. Encoding to
//! instances rather than issuing a draw call per shape is what lets a full screen become one GPU
//! submission, which is where the acceleration comes from.
//!
//! This module encodes; it issues no GPU calls itself. A driver layer submits the buffer to Vulkan or
//! Metal. Keeping the encoder pure makes the CPU→GPU translation testable without a GPU.

const std = @import("std");
const paint = @import("paint.zig");
const fb = @import("framebuffer.zig");

const Rgba = fb.Rgba;
const Rect = paint.Rect;

/// The shape a quad instance evaluates in the fragment shader.
pub const Kind = enum(u8) {
    solid = 0,
    vgradient = 1,
    rounded = 2,
    rounded_vgradient = 3,
};

/// One quad instance: everything the GPU shader needs to shade a paint command over a unit quad, in
/// device pixels. `top` is the sole colour for a solid; `top`/`bottom` are the gradient stops.
pub const Instance = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    kind: u32,
    top: [4]u8,
    bottom: [4]u8,
};

fn colour(c: Rgba) [4]u8 {
    return .{ c.r, c.g, c.b, c.a };
}

fn instanceFor(command: paint.Command) Instance {
    return switch (command) {
        .solid => |c| .{
            .x = @floatFromInt(c.rect.x),
            .y = @floatFromInt(c.rect.y),
            .w = @floatFromInt(c.rect.w),
            .h = @floatFromInt(c.rect.h),
            .radius = 0,
            .kind = @intFromEnum(Kind.solid),
            .top = colour(c.colour),
            .bottom = colour(c.colour),
        },
        .vgradient => |c| .{
            .x = @floatFromInt(c.rect.x),
            .y = @floatFromInt(c.rect.y),
            .w = @floatFromInt(c.rect.w),
            .h = @floatFromInt(c.rect.h),
            .radius = 0,
            .kind = @intFromEnum(Kind.vgradient),
            .top = colour(c.top),
            .bottom = colour(c.bottom),
        },
        .rounded => |c| .{
            .x = @floatFromInt(c.rect.x),
            .y = @floatFromInt(c.rect.y),
            .w = @floatFromInt(c.rect.w),
            .h = @floatFromInt(c.rect.h),
            .radius = @floatFromInt(c.radius),
            .kind = @intFromEnum(Kind.rounded),
            .top = colour(c.colour),
            .bottom = colour(c.colour),
        },
        .rounded_vgradient => |c| .{
            .x = @floatFromInt(c.rect.x),
            .y = @floatFromInt(c.rect.y),
            .w = @floatFromInt(c.rect.w),
            .h = @floatFromInt(c.rect.h),
            .radius = @floatFromInt(c.radius),
            .kind = @intFromEnum(Kind.rounded_vgradient),
            .top = colour(c.top),
            .bottom = colour(c.bottom),
        },
    };
}

/// Encodes a display list into an instance buffer, preserving order (instance N is drawn over instance
/// N-1, matching the CPU path's back-to-front compositing). The caller owns the returned slice.
pub fn encode(allocator: std.mem.Allocator, commands: []const paint.Command) ![]Instance {
    const buffer = try allocator.alloc(Instance, commands.len);
    for (commands, 0..) |command, index| buffer[index] = instanceFor(command);
    return buffer;
}

const testing = std.testing;

test "every command encodes to one instance, in order" {
    const commands = [_]paint.Command{
        .{ .solid = .{ .rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 }, .colour = .{ .r = 10, .g = 20, .b = 30, .a = 255 } } },
        .{ .rounded = .{ .rect = .{ .x = 5, .y = 6, .w = 7, .h = 8 }, .radius = 2, .colour = .{ .r = 1, .g = 2, .b = 3, .a = 255 } } },
    };
    const buffer = try encode(testing.allocator, &commands);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(@as(usize, 2), buffer.len);
    try testing.expectEqual(@as(u32, @intFromEnum(Kind.solid)), buffer[0].kind);
    try testing.expectEqual(@as(f32, 1), buffer[0].x);
    try testing.expectEqual(@as(u32, @intFromEnum(Kind.rounded)), buffer[1].kind);
    try testing.expectEqual(@as(f32, 2), buffer[1].radius);
}

test "geometry and colours survive encoding" {
    const commands = [_]paint.Command{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 },
        .top = .{ .r = 200, .g = 100, .b = 50, .a = 255 },
        .bottom = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
    } }};
    const buffer = try encode(testing.allocator, &commands);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(@as(u32, @intFromEnum(Kind.vgradient)), buffer[0].kind);
    try testing.expectEqual([4]u8{ 200, 100, 50, 255 }, buffer[0].top);
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, buffer[0].bottom);
    try testing.expectEqual(@as(f32, 100), buffer[0].w);
}

test "an empty display list encodes to an empty buffer" {
    const buffer = try encode(testing.allocator, &.{});
    defer testing.allocator.free(buffer);
    try testing.expectEqual(@as(usize, 0), buffer.len);
}

test "encoding is deterministic" {
    const commands = [_]paint.Command{
        .{ .solid = .{ .rect = .{ .x = 3, .y = 3, .w = 3, .h = 3 }, .colour = .{ .r = 9, .g = 9, .b = 9, .a = 255 } } },
    };
    const a = try encode(testing.allocator, &commands);
    defer testing.allocator.free(a);
    const b = try encode(testing.allocator, &commands);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(Instance, a, b);
}

test "the instance count equals the command count for any list, swept" {
    // The one-instance-per-command property: the GPU submission has exactly as many quads as the
    // display list has commands, so nothing is dropped or duplicated in translation.
    const lists = [_][]const paint.Command{
        &.{},
        &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .colour = .{ .r = 0, .g = 0, .b = 0 } } }},
        &.{
            .{ .rounded = .{ .rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .radius = 1, .colour = .{ .r = 1, .g = 1, .b = 1 } } },
            .{ .rounded_vgradient = .{ .rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .radius = 1, .top = .{ .r = 2, .g = 2, .b = 2 }, .bottom = .{ .r = 3, .g = 3, .b = 3 } } },
        },
    };
    for (lists) |list| {
        const buffer = try encode(testing.allocator, list);
        defer testing.allocator.free(buffer);
        try testing.expectEqual(list.len, buffer.len);
    }
}
