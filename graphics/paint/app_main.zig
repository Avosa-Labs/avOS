//! Renders a named app screen to a PNG.
//!
//! Usage: app <phone|messages|calendar|camera> [OUTPUT.png]

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const apps = @import("apps.zig");
const theme = @import("design").theme;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    if (args.len < 2) {
        try err.print("usage: app <phone|messages|calendar|camera> [out.png]\n", .{});
        try err.flush();
        return 2;
    }

    const app: apps.App = if (std.mem.eql(u8, args[1], "phone"))
        .phone
    else if (std.mem.eql(u8, args[1], "messages"))
        .messages
    else if (std.mem.eql(u8, args[1], "calendar"))
        .calendar
    else if (std.mem.eql(u8, args[1], "camera"))
        .camera
    else {
        try err.print("app: unknown app '{s}'\n", .{args[1]});
        try err.flush();
        return 2;
    };

    const output = if (args.len > 2) args[2] else "app.png";

    var target = try fb.Framebuffer.init(gpa, apps.width, apps.height, paint.sample(theme.base));
    defer target.deinit();
    apps.render(&target, app);

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("app: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}
