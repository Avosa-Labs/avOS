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
/// Whether this build owns a leak-failing allocator around the whole render (the `leak-check` gate turns
/// it on; every other build leaves it off, so the ordinary `zig build shell` path is byte-identical).
const leak_options = @import("leak_options");

const Framebuffer = graphics.framebuffer.Framebuffer;
const theme = design.theme;

fn parseSurface(name: []const u8) ?live.Surface {
    return std.meta.stringToEnum(live.Surface, name);
}

fn baseFill() graphics.framebuffer.Rgba {
    return .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = 255 };
}

pub fn main(init: std.process.Init) !u8 {
    // The default path leans on nothing but the process allocator, so `zig build shell` is unchanged.
    if (!leak_options.enforce) return run(init, init.gpa);

    // The leak gate: own a checking allocator so its verdict is not the one start.zig discards, back the
    // whole render with it, and turn a detected leak into a non-zero exit the build step fails on. Its
    // own page-backed pages mean it works identically whether or not the exe links libc.
    var checked: std.heap.DebugAllocator(.{}) = .init;
    const code = run(init, checked.allocator()) catch |err| {
        _ = checked.deinit();
        return err;
    };
    if (checked.deinit() == .leak) {
        var buf: [256]u8 = undefined;
        var ef = io_adapters.stderr(init.io, &buf);
        try ef.interface.print("shell: allocation leak detected\n", .{});
        try ef.interface.flush();
        return 1;
    }
    return code;
}

/// The render itself, over an explicit general-purpose allocator so the leak gate can back it with a
/// checking allocator. The arena stays `init.arena` — page-backed and freed wholesale, deliberately
/// outside the checker, since its scratch is never individually freed and is not a leak.
fn run(init: std.process.Init, gpa: std.mem.Allocator) !u8 {
    const io = init.io;
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

    // The leak gate's scenario: render every surface once into one reused in-memory framebuffer, writing
    // no files. It drives the whole render bridge — every app surface, not just the session's eight —
    // through the caller's allocator, so a leak anywhere the OS renders is caught headless and offline.
    if (std.mem.eql(u8, which, "leakcheck")) return renderEverySurface(gpa, &host);

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
    // The Clock surface reads the device's real wall clock; captured before seeding so the agent's world
    // time and the surface's own read the same instant. Other surfaces keep the deterministic default.
    if (surface == .clock) idle.captureDeviceTime(io);
    // Run each in-app agent's real work once, so an app surface shows its genuine last agent action
    // derived from the domain — not a static chip. Weather is refreshed on its own live path below.
    live.seedAgentPresence(&idle);
    // Resolve the device's real location and fetch its live weather, so the weather surface reads where
    // this host actually is. A host with no network stays honestly unlocated.
    if (surface == .weather) idle.weatherRefresh(gpa, io);
    try live.renderSurface(&target, &host, surface, t, &idle);

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("shell: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}

/// Renders every surface once into one reused, in-memory framebuffer — writing nothing — so the leak
/// gate exercises the full render bridge on a headless host. Returns 0; a leak is reported by the owned
/// checker in `main`, not here.
fn renderEverySurface(gpa: std.mem.Allocator, host: *live.Host) !u8 {
    var idle = live.Interaction{};
    idle.attach(gpa);
    defer idle.release();
    live.seedAgentPresence(&idle);
    var target = try Framebuffer.init(gpa, live.width, live.height, baseFill());
    defer target.deinit();
    for (std.enums.values(live.Surface)) |surface| {
        try live.renderSurface(&target, host, surface, 0.0, &idle);
    }
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
    live.seedAgentPresence(&idle);
    for (sequence) |frame| {
        var target = try Framebuffer.init(gpa, live.width, live.height, baseFill());
        defer target.deinit();
        try live.renderSurface(&target, host, frame.surface, 0.0, &idle);
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
