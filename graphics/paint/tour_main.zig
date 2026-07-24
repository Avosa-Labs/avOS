//! Renders the whole tour contact sheet to a PNG.
//!
//! Usage: tour [OUTPUT.png]  (defaults to tour.png)

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const tour = @import("tour.zig");
const theme = @import("design").theme;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const output = if (args.len > 1) args[1] else "tour.png";

    var sheet = try fb.Framebuffer.init(gpa, tour.sheetWidth(), tour.sheetHeight(), paint.sample(theme.base));
    defer sheet.deinit();
    try tour.render(gpa, &sheet);

    const png = try sheet.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("tour: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}
