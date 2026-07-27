//! The headless shell front end: renders the live designed surfaces to PNG files.
//!
//! This is the front end for hosts without a display — it runs the canonical scenario and writes the
//! designed surfaces, produced from that run's real state, as images. The windowed desktop shell shares
//! the same rendering (`live_render`); this one just encodes to files. `session` writes the whole
//! sequence boot-to-rest; a single surface name writes that one.
//!
//! Usage: shell <session|home|activity|approval|principals|store|boot|rest> [OUTPUT]

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const live = @import("live_render");
const graphics = @import("graphics");
const design = @import("design");

const Framebuffer = graphics.framebuffer.Framebuffer;
const theme = design.theme;

fn parseSurface(name: []const u8) ?live.Surface {
    return std.meta.stringToEnum(live.Surface, name);
}

fn baseFill() graphics.framebuffer.Rgba {
    return .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = 255 };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const which = if (args.len > 1) args[1] else "activity";

    var host: live.Host = undefined;
    try live.runScenario(&host, gpa);
    defer host.deinit();
    live.arrangePendingApproval(&host);

    if (std.mem.eql(u8, which, "session")) {
        const prefix = if (args.len > 2) args[2] else "session_";
        return renderSession(gpa, io, err, &host, prefix);
    }

    const surface = parseSurface(which) orelse {
        try err.print("shell: unknown surface '{s}'\n", .{which});
        try err.flush();
        return 2;
    };
    const output = if (args.len > 2) args[2] else "shell.png";
    // An optional time (seconds) lets a caller sample an animated surface at a chosen instant —
    // the boot reveal, the lock ring — rather than only the t=0 frame.
    const t: f32 = if (args.len > 3) (std.fmt.parseFloat(f32, args[3]) catch 0.0) else 0.0;

    var target = try Framebuffer.init(gpa, live.width, live.height, baseFill());
    defer target.deinit();
    var idle = live.Interaction{};
    idle.attach(gpa);
    defer idle.release();
    try live.renderSurface(gpa, &target, &host, surface, t, &idle);

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("shell: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}

/// Writes the whole session — boot, home, and the live agent-native surfaces, then rest — as numbered
/// frames under `prefix`.
fn renderSession(gpa: std.mem.Allocator, io: anytype, err: anytype, host: *live.Host, prefix: []const u8) !u8 {
    const sequence = [_]struct { name: []const u8, surface: live.Surface }{
        .{ .name = "00_boot", .surface = .boot },
        .{ .name = "01_lock", .surface = .lock },
        .{ .name = "02_home", .surface = .home },
        .{ .name = "03_activity", .surface = .activity },
        .{ .name = "04_approval", .surface = .approval },
        .{ .name = "05_principals", .surface = .principals },
        .{ .name = "06_store", .surface = .store },
        .{ .name = "07_rest", .surface = .rest },
    };
    var idle = live.Interaction{};
    idle.attach(gpa);
    defer idle.release();
    for (sequence) |frame| {
        var target = try Framebuffer.init(gpa, live.width, live.height, baseFill());
        defer target.deinit();
        try live.renderSurface(gpa, &target, host, frame.surface, 0.0, &idle);
        const png = try target.encodePng(gpa);
        defer gpa.free(png);
        const path = try std.fmt.allocPrint(gpa, "{s}{s}.png", .{ prefix, frame.name });
        defer gpa.free(path);
        io_adapters.writeFile(io_adapters.cwd(), io, path, png) catch {
            try err.print("shell: cannot write '{s}'\n", .{path});
            try err.flush();
            return 1;
        };
    }
    return 0;
}
