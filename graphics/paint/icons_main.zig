//! Renders the app icon sheet to a PNG — every tile with its glyph, in one image.
//!
//! Where the frame demonstration shows the tiles as bare gradients, this renders the finished icons:
//! each squircle in its per-app gradient with its white line symbol on top. It is how the icon set is
//! checked against the reference — laid out on the base wallpaper, at a real size, exactly as the home
//! screen will place them. Later the home screen composes the same `iconography.draw` call; this sheet
//! is the isolated view of just the icons.
//!
//! Usage: icons [OUTPUT.png]  (defaults to icons.png)

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const iconography = @import("iconography.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const apps = [_]iconography.App{ .phone, .messages, .calendar, .camera, .health, .agents, .files, .settings };
const labels = [_][]const u8{ "Phone", "Messages", "Calendar", "Camera", "Health", "Agents", "Files", "Settings" };

const cols: u32 = 4;
const rows: u32 = 2;
const tile: u32 = 96;
const gap: u32 = 46; // room for a label beneath each row
const margin: u32 = 36;
const label_band: u32 = 30; // extra height under the last row for its labels

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const output = if (args.len > 1) args[1] else "icons.png";

    const width = margin * 2 + cols * tile + (cols - 1) * gap;
    const height = margin * 2 + rows * tile + (rows - 1) * gap + label_band;

    var target = try fb.Framebuffer.init(gpa, width, height, paint.sample(theme.base));
    defer target.deinit();

    // Wallpaper gradient behind the sheet.
    paint.paint(&target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = paint.sample(theme.base),
        .bottom = paint.sample(theme.panel),
    } }});

    for (apps, 0..) |app, index| {
        const col: u32 = @intCast(index % cols);
        const row: u32 = @intCast(index / cols);
        const x: i32 = @intCast(margin + col * (tile + gap));
        const y: i32 = @intCast(margin + row * (tile + gap));
        iconography.draw(&target, .{ .x = x, .y = y, .w = tile, .h = tile }, app);
        // The app name centred under the tile, in the secondary text tone.
        const centre_x = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(tile)) / 2.0;
        const label_baseline = @as(f32, @floatFromInt(y + @as(i32, @intCast(tile)))) + 22.0;
        text.drawCentred(&target, centre_x, label_baseline, labels[index], 15.0, paint.sample(theme.text_primary));
    }

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("icons: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}
