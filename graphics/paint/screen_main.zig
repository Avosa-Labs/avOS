//! Renders a named shell screen to a PNG.
//!
//! Usage: screen <approval|ledger|principals> [OUTPUT.png]

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const screens = @import("screens.zig");
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
        try err.print("usage: screen <approval|ledger|principals> [out.png]\n", .{});
        try err.flush();
        return 2;
    }

    const screen: screens.Screen = if (std.mem.eql(u8, args[1], "approval"))
        .approval
    else if (std.mem.eql(u8, args[1], "ledger"))
        .ledger
    else if (std.mem.eql(u8, args[1], "principals"))
        .principals
    else {
        try err.print("screen: unknown screen '{s}'\n", .{args[1]});
        try err.flush();
        return 2;
    };

    const output = if (args.len > 2) args[2] else "screen.png";

    var target = try fb.Framebuffer.init(gpa, screens.width, screens.height, paint.sample(theme.base));
    defer target.deinit();
    screens.render(&target, screen);

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("screen: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}
