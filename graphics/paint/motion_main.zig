//! Renders the agent-card entrance as a sequence of animation frames.
//!
//! Usage: motion [PREFIX] [FRAMES]  (defaults to motion_ and 10)

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const motion = @import("motion.zig");
const theme = @import("design").theme;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const prefix = if (args.len > 1) args[1] else "motion_";
    const frames: u32 = if (args.len > 2) (std.fmt.parseUnsigned(u32, args[2], 10) catch 10) else 10;

    var index: u32 = 0;
    while (index < frames) : (index += 1) {
        const progress: f32 = if (frames <= 1) 1.0 else @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(frames - 1));
        var target = try fb.Framebuffer.init(gpa, motion.width, motion.height, paint.sample(theme.base));
        defer target.deinit();
        motion.renderFrame(&target, progress);
        const png = try target.encodePng(gpa);
        defer gpa.free(png);
        const path = try std.fmt.allocPrint(gpa, "{s}{d:0>2}.png", .{ prefix, index });
        defer gpa.free(path);
        io_adapters.writeFile(io_adapters.cwd(), io, path, png) catch {
            try err.print("motion: cannot write '{s}'\n", .{path});
            try err.flush();
            return 1;
        };
    }
    return 0;
}
