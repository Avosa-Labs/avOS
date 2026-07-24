//! Renders a demonstration frame to a PNG, the first thing the render pipeline draws that a person can
//! actually look at.
//!
//! The frame is small but real: the wallpaper gradient the shell rests on, a raised panel, and a row of
//! the eight app icon tiles in the platform's squircle shape and gradient palette. It exists to prove
//! the pipeline end to end — display list, painter, framebuffer, encoder — produces a correct image on
//! any host, with no GPU and no image library. Later scenes replace the demonstration content; the path
//! from a display list to a file stays the same.
//!
//! Usage: frame [OUTPUT.png]  (defaults to frame.png)

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const theme = @import("design").theme;

const width: u32 = 480;
const height: u32 = 320;

fn tile(x: i32, y: i32, size: u32, gradient: theme.Gradient) paint.Command {
    const radius = @as(u32, size) * theme.icon_radius_ratio_num / theme.icon_radius_ratio_den;
    return .{ .rounded_vgradient = .{
        .rect = .{ .x = x, .y = y, .w = size, .h = size },
        .radius = radius,
        .top = paint.sample(gradient.top),
        .bottom = paint.sample(gradient.bottom),
    } };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const output = if (args.len > 1) args[1] else "frame.png";

    var target = try fb.Framebuffer.init(gpa, width, height, paint.sample(theme.base));
    defer target.deinit();

    const icons = [_]theme.Gradient{
        theme.icon_phone,  theme.icon_messages, theme.icon_calendar, theme.icon_camera,
        theme.icon_health, theme.icon_agents,   theme.icon_files,    theme.icon_settings,
    };

    var commands: std.ArrayList(paint.Command) = .empty;
    defer commands.deinit(gpa);

    // Wallpaper: a vertical gradient from the base to the panel tone.
    try commands.append(gpa, .{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = paint.sample(theme.base),
        .bottom = paint.sample(theme.panel),
    } });
    // A raised panel with soft rounded corners.
    try commands.append(gpa, .{ .rounded = .{
        .rect = .{ .x = 32, .y = 40, .w = width - 64, .h = height - 80 },
        .radius = theme.radius_xl,
        .colour = paint.sample(theme.surface),
    } });
    // The eight app icon tiles in a row, in the squircle shape.
    const size: u32 = 44;
    const gap: i32 = 8;
    const total: i32 = @as(i32, icons.len) * @as(i32, size) + (@as(i32, icons.len) - 1) * gap;
    var x: i32 = @divTrunc(@as(i32, width) - total, 2);
    const y: i32 = @divTrunc(@as(i32, height) - @as(i32, size), 2);
    for (icons) |gradient| {
        try commands.append(gpa, tile(x, y, size, gradient));
        x += @as(i32, size) + gap;
    }

    paint.paint(&target, commands.items);

    const png = try target.encodePng(gpa);
    defer gpa.free(png);

    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("frame: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}
