//! Renders the home screen to a PNG.
//!
//! Usage: home [OUTPUT.png]  (defaults to home.png)

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const phone = @import("phone.zig");
const home = @import("home.zig");
const theme = @import("design").theme;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const output = if (args.len > 1) args[1] else "home.png";

    var target = try fb.Framebuffer.init(gpa, phone.window_w, phone.window_h, paint.sample(theme.base));
    defer target.deinit();

    phone.renderDevice(&target);
    var screen = try phone.blankScreen(gpa);
    defer screen.deinit();
    phone.screenWash(&screen);
    phone.statusBar(&screen);
    home.render(&screen, home.demo, 0.0);
    phone.homeIndicator(&screen);
    phone.composite(&target, screen);

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("home: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}
