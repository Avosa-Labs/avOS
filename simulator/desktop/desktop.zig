//! The windowed desktop shell: the actual OS running in a real window.
//!
//! This is the OS you run and see. It opens a window through SDL — which is backed by Metal on macOS
//! and Vulkan or the platform compositor on Linux — runs the canonical scenario once for live state,
//! and then drives a real render loop: every frame it paints the current surface from that run's real
//! audit ledger, registry, and store decisions into a framebuffer, uploads it to a GPU texture, and
//! presents it. Mouse input navigates between surfaces — the home agent card opens the held approval,
//! the app grid opens the activity ledger, the dock opens the store, and tapping the header returns
//! home — and each navigation fades in with the design's spring easing. So this is the design as a
//! living OS: real agents, real decisions, a real window, real input, drawn on the GPU.
//!
//! Run it with `zig build run`. It requires a display and SDL2; on a headless host use `zig build
//! shell -- session` to render the same surfaces to images instead.

const std = @import("std");
const builtin = @import("builtin");
const live = @import("live_render");
const graphics = @import("graphics");
const design = @import("design");
const mind_provider = @import("mind_provider");
/// The device's real audio backend, bound into the shell's screening path per-OS (see `audio_apple` /
/// `audio_native`): CoreAudio on macOS, an inert binder that leaves the seam honestly unbound elsewhere.
const audio_bind = @import("audio_bind");
/// The device's real camera backend, bound into the shell's Camera capture path per-OS (see
/// `camera_apple` / `camera_native`): AVFoundation on macOS, an inert binder that leaves the seam
/// honestly dark elsewhere.
const camera_bind = @import("camera_bind");
/// Whether this build owns a leak-failing allocator around the whole session (turned on with
/// -Dleak-check=true). Off by default, so `zig build run` is unchanged; when on, closing the window
/// exits non-zero on a detected leak, keeping the desktop honest on exit and parallel with the shell.
const leak_options = @import("leak_options");

const c = @import("sdl.zig");

/// The device's real location from the platform's native location service (see `location_native`).
/// Writes the coordinate and the locality name; returns 0 on success, non-zero when unavailable.
extern fn device_current_location(out_lat: *f64, out_lon: *f64, city_buf: [*]u8, city_cap: c_int) c_int;

/// Where a provisioned on-device model lives, relative to the working directory. `zig build fetch-model`
/// writes the default model here; the directory is ignored by git and never committed.
const models_dir = ".models";

/// Resolves the on-device model to load, so `zig build run` just works with no configuration. A custom
/// agent may point `LOCAL_MODEL_PATH` at its own weights; otherwise the first provisioned `.gguf` in the
/// local models directory is used automatically. Returns an empty path when none is present, which
/// leaves the assistant honestly offline. The path is written into `buf` when auto-discovered.
fn resolveModelPath(init: std.process.Init, buf: []u8) []const u8 {
    // A custom agent's configured model overrides discovery.
    if (init.environ_map.get("LOCAL_MODEL_PATH")) |configured| {
        if (configured.len > 0) return configured;
    }
    // Otherwise auto-detect a provisioned model: the first .gguf in the local models directory.
    var base = std.Io.Dir.cwd();
    var dir = base.openDir(init.io, models_dir, .{ .iterate = true }) catch return "";
    defer dir.close(init.io);
    var it = dir.iterate();
    while (it.next(init.io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".gguf")) {
            return std.fmt.bufPrint(buf, models_dir ++ "/{s}", .{entry.name}) catch "";
        }
    }
    return "";
}

/// Fetches live weather at the device's real location. It asks the platform's native location service
/// first — accurate to the actual place — and falls back to the cross-platform IP lookup only when no
/// native fix is available (an OS without a wired backend, or the person has not authorized location).
fn resolveWeather(interaction: *live.Interaction, gpa: std.mem.Allocator, io: std.Io) void {
    var lat: f64 = 0;
    var lon: f64 = 0;
    var city: [64]u8 = undefined;
    if (device_current_location(&lat, &lon, &city, city.len) == 0) {
        const end = std.mem.indexOfScalar(u8, &city, 0) orelse city.len;
        interaction.weatherRefreshAt(gpa, io, lat, lon, city[0..end]);
        return;
    }
    interaction.weatherRefresh(gpa, io);
}

const Framebuffer = graphics.framebuffer.Framebuffer;
const anim = graphics.anim;
const theme = design.theme;

const W: c_int = @intCast(live.width);
const H: c_int = @intCast(live.height);

/// Decides the next surface from a tap, so the window is navigable: the home agent card opens the
/// approval, the app grid opens the activity ledger, the dock opens the store; on any sub-surface a tap
/// in the header returns home and a tap in the body advances through the agent-native surfaces.
fn navigate(current: live.Surface, mx: i32, my: i32) live.Surface {
    // Into the light screen's own coordinates.
    const sx = mx - graphics.phone.screen_x;
    const sy = my - graphics.phone.screen_y;
    const screen_w: i32 = @intCast(graphics.phone.screen_w);
    const screen_h: i32 = @intCast(graphics.phone.screen_h);

    // Boot and lock are the opening cycle: a tap anywhere skips boot to the lock screen, and a tap
    // (or swipe) on the lock screen opens the home screen — the reference's "Swipe up to open".
    if (current == .boot) return .lock;
    if (current == .lock) return .home;

    // The back button: a small target at the top-left of every sub-surface returns to where the app
    // was opened from. It is the ONLY way out — tapping the body never closes the app.
    if (current != .home and current != .library) {
        if (sx < 64 and sy < 96) return .home;
    }
    if (current == .library and sx < 64 and sy < 96) return .home;

    if (current == .home) {
        // The dock and the app grid: hit-test each tile so a tap opens that app, not a band.
        if (dockApp(sx, sy, screen_w, screen_h)) |app| return app;
        if (live.homeGridApp(sx, sy)) |app_surface| return app_surface;
        if (live.homeAllApps(sx, sy)) return .library; // "All apps" opens the full list
        return .home; // the home body stays home
    }

    // The library: a tap on a tile opens that app; anything else stays in the library.
    if (current == .library) {
        if (live.libraryApp(sx, sy)) |app_surface| return app_surface;
        return .library;
    }

    // On any app surface, a body tap that missed every control stays in the app — it never closes.
    return current;
}

/// The app a tap on the dock opens, or null if the tap is not on the dock. The layout
/// mirrors `graphics.home.dock` exactly, so the tiles the person sees are the tiles hit.
fn dockApp(sx: i32, sy: i32, screen_w: i32, screen_h: i32) ?live.Surface {
    const dock_h: i32 = 76;
    const dock_y = screen_h - dock_h - 26;
    if (sy < dock_y or sy > dock_y + dock_h) return null;

    const apps = graphics.home.dock_apps; // phone, messages, camera, agents
    const tile: i32 = 52;
    const rect_x: i32 = 16;
    const rect_w = screen_w - 32;
    const inner = rect_w - 44;
    const gap = @divTrunc(inner - @as(i32, @intCast(apps.len)) * tile, @as(i32, @intCast(apps.len)) - 1);
    const iy = dock_y + @divTrunc(dock_h - tile, 2);
    if (sy < iy - 8 or sy > iy + tile + 8) return null;

    for (apps, 0..) |app, i| {
        const ix = rect_x + 22 + @as(i32, @intCast(i)) * (tile + gap);
        if (sx >= ix - 8 and sx <= ix + tile + 8) {
            return switch (app) {
                .phone => .phone,
                .messages => .messages,
                .camera => .camera,
                .agents => .agents, // the agents tile opens the Agents flagship
                else => .activity,
            };
        }
    }
    return null;
}

/// Whether a surface carries continuous motion of its own, so the loop must keep repainting it
/// frame after frame. The opening cycle reveals and breathes, the wind-down plays, and the clock's
/// hands sweep; every other surface holds still until input or live state moves it, so an idle home
/// or app surface is painted once and then leaves the GPU alone.
fn surfaceAnimates(surface: live.Surface) bool {
    return switch (surface) {
        .boot, .lock, .shutdown, .clock => true,
        else => false,
    };
}

/// The factor to scale the full-resolution device into a window that fits the display,
/// with a little breathing room. Never scales up: a device smaller than the screen opens
/// at its own size. Falls back to 1:1 if the display bounds cannot be read.
fn windowScale(w: c_int, h: c_int) f32 {
    var bounds: c.Rect = undefined;
    if (c.SDL_GetDisplayUsableBounds(0, &bounds) != 0) return 1.0;
    if (bounds.w <= 0 or bounds.h <= 0) return 1.0;
    const breathing_room: f32 = 0.92;
    const by_height = @as(f32, @floatFromInt(bounds.h)) * breathing_room / @as(f32, @floatFromInt(h));
    const by_width = @as(f32, @floatFromInt(bounds.w)) * breathing_room / @as(f32, @floatFromInt(w));
    return @min(@min(by_height, by_width), 1.0);
}

pub fn main(init: std.process.Init) !u8 {
    // The default path leans on nothing but the process allocator, so `zig build run` is unchanged.
    if (!leak_options.enforce) return run(init, init.gpa);

    // The leak gate: own a checking allocator so its verdict is not the one start.zig discards, back the
    // whole session with it, and turn a detected leak into a non-zero exit once the window closes.
    var checked: std.heap.DebugAllocator(.{}) = .init;
    const code = run(init, checked.allocator()) catch |err| {
        _ = checked.deinit();
        return err;
    };
    if (checked.deinit() == .leak) {
        std.debug.print("desktop: allocation leak detected\n", .{});
        return 1;
    }
    return code;
}

/// The windowed session, over an explicit general-purpose allocator so the leak gate can back it with a
/// checking allocator. Returns 0 when the window closes.
fn run(init: std.process.Init, gpa: std.mem.Allocator) !u8 {
    var host: live.Host = undefined;
    try live.runScenario(&host, gpa);
    defer host.deinit();
    // A held action the person can actually decide on the approval screen — the two doors, live.
    live.arrangePendingApproval(&host);

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.print("desktop: SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        std.debug.print("desktop: this host has no display. Use 'zig build shell -- session' to render to images.\n", .{});
        return 1;
    }
    defer c.SDL_Quit();

    // The framebuffer is the device at its full logical resolution; the window is that
    // device scaled to fit the display. Rendering at full resolution keeps the phone
    // crisp, while fitting the window keeps the whole device on screen — a tall device
    // must never open a window taller than the screen it opens on.
    const fit = windowScale(W, H);
    const win_w: c_int = @intFromFloat(@as(f32, @floatFromInt(W)) * fit);
    const win_h: c_int = @intFromFloat(@as(f32, @floatFromInt(H)) * fit);

    const window = c.SDL_CreateWindow(
        "Personal OS",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        win_w,
        win_h,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_ALLOW_HIGHDPI,
    ) orelse {
        std.debug.print("desktop: SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return 1;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC) orelse {
        std.debug.print("desktop: SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return 1;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // ABGR8888 stores bytes as R,G,B,A on a little-endian host — the framebuffer's own layout.
    const texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, W, H) orelse {
        std.debug.print("desktop: SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
        return 1;
    };
    defer c.SDL_DestroyTexture(texture);

    var fb = try Framebuffer.init(gpa, live.width, live.height, .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = 255 });
    defer fb.deinit();

    // A surface change is an instant cut: the new screen is painted straight into the framebuffer with no
    // crossfade, slide, or veil — nothing of the previous screen is ever left on screen, so a tap can
    // never read as a trace, a flash, or lag. Motion lives inside a surface (the boot reveal, breathing
    // dots), not between them.
    var surface: live.Surface = .boot;
    var interaction: live.Interaction = .{}; // live state a tap changes (the calculator keypad, the store, …)
    interaction.attach(gpa);
    defer interaction.release();
    // The Clock surface reads the device's real wall clock; captured before seeding so the agent's world
    // time and the surface's own read the same instant.
    interaction.captureDeviceTime(init.io);
    // Run each in-app agent's real work once, so every app opens showing its genuine last agent action
    // derived from its domain — the Files organize, the Calendar propose and held commit, and the rest.
    live.seedAgentPresence(&interaction);
    // Bind the on-device model to the assistant. `zig build run` works with no configuration: a model
    // provisioned into the local models directory is discovered automatically. A custom agent can point
    // LOCAL_MODEL_PATH at its own weights. With no model present the mind stays honestly offline.
    var model_buf: [512]u8 = undefined;
    mind_provider.tryLoad(&interaction, resolveModelPath(init, &model_buf));
    // Fetch live weather at the device's real location. Prefer CoreLocation (GPS/Wi-Fi, accurate to the
    // actual place) on macOS; fall back to the coarse IP lookup when it is unavailable or unauthorized.
    resolveWeather(&interaction, gpa, init.io);
    // Bind the device's real audio backend into the Phone screening path. On macOS this is CoreAudio, so
    // the screening agent finds a real capture+playback route; on a platform without a wired backend the
    // seam stays unbound and the path reports audio honestly unavailable. Binding enumerates nothing and
    // opens no stream, so it never lights the microphone.
    audio_bind.bind(&interaction);
    // Bind the device's real camera backend into the Camera capture path. On macOS this is AVFoundation,
    // so a shutter press takes a real frame where a device exists; on a platform without a wired backend
    // the seam stays dark and the path is honestly frameless. Binding enumerates nothing and starts no
    // session, so it never lights the camera — only opening the viewfinder (below) does.
    camera_bind.bind(&interaction);
    var boot_seen: u32 = 0;
    var shutdown_frames: u32 = 0; // frames since the device began winding down
    var lock_seen: u32 = 0;
    var frames: u32 = 0;
    var running = true;
    var event: c.SDL_Event = undefined;
    c.SDL_StartTextInput(); // the home command bar accepts a typed question for the assistant

    // Repaint only when the frame would actually differ: on the first pass, when input or an
    // auto-advance moved the surface, or while a self-animating surface is on screen. A still
    // surface with no input costs the GPU nothing. `dirty` starts set so the first frame paints.
    var dirty = true;
    var prev_surface: live.Surface = surface;

    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            // Any event we act on can move state, so the next frame must be repainted.
            dirty = true;
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    const key = event.key.keysym.sym;
                    if (key == c.SDLK_ESCAPE) running = false;
                    // Power controls: S winds the device down to black; R restarts, replaying the boot
                    // cycle — the shutdown and restart the design calls for.
                    if (key == c.SDLK_s) {
                        surface = .shutdown;
                        shutdown_frames = 0;
                    } else if (key == c.SDLK_r) {
                        surface = .boot;
                        boot_seen = 0;
                    }
                    // Up / space / return is the "swipe up to open": it skips boot to the lock screen
                    // and unlocks the lock screen to home. Confined to the opening cycle so it never
                    // stray-navigates an app surface.
                    if ((surface == .boot or surface == .lock) and
                        (key == c.SDLK_UP or key == c.SDLK_SPACE or key == c.SDLK_RETURN))
                    {
                        surface = if (surface == .boot) .lock else .home;
                    }
                    // On home, the command bar is the assistant: Return sends the typed question to the
                    // on-device model, Backspace edits it.
                    if ((surface == .home or surface == .calculator) and key == c.SDLK_RETURN) mind_provider.ask(&interaction);
                    if ((surface == .home or surface == .calculator) and key == c.SDLK_BACKSPACE) interaction.assistantBackspace();
                    // In messaging, the compose bar takes the keyboard: Return sends the typed message
                    // (or starts the conversation on the new-conversation screen), Backspace edits it.
                    if (surface == .messages and key == c.SDLK_RETURN) {
                        if (interaction.composing_new) interaction.msgConfirmConversation() else interaction.msgSend();
                    }
                    if (surface == .messages and key == c.SDLK_BACKSPACE) interaction.msgComposeBackspace();
                },
                c.SDL_TEXTINPUT => {
                    // Typed characters go into whichever text field is active: the home command bar, or
                    // the messaging compose bar when a thread or the new-conversation screen is open.
                    if (surface == .home or surface == .calculator) {
                        for (event.text.text) |byte| {
                            if (byte == 0) break;
                            interaction.assistantType(byte);
                        }
                    } else if (surface == .messages and (interaction.open_conv != null or interaction.composing_new)) {
                        for (event.text.text) |byte| {
                            if (byte == 0) break;
                            interaction.msgComposeType(byte);
                        }
                    }
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    // The click arrives in window coordinates; map it back to the
                    // device's full-resolution coordinates the surfaces are laid out in.
                    const mx: i32 = @intFromFloat(@as(f32, @floatFromInt(event.button.x)) / fit);
                    const my: i32 = @intFromFloat(@as(f32, @floatFromInt(event.button.y)) / fit);
                    // On an interactive surface, a tap on a control acts on it and does not navigate; a
                    // tap that misses every control falls through to navigation (e.g. the header → home).
                    const sx = mx - graphics.phone.screen_x;
                    const sy = my - graphics.phone.screen_y;
                    if (surface == .calculator and live.calcTap(&interaction, sx, sy)) {
                        // handled by the keypad
                    } else if (surface == .approval and live.approvalDecide(&host, sx, sy)) {
                        // handled by the Approve/Hold buttons
                    } else if (surface == .store and live.storeTap(&interaction, sx, sy)) {
                        // handled by an install button
                    } else if (surface == .messages and live.messagesTap(&interaction, sx, sy)) {
                        // handled by the send button
                    } else if (surface == .phone and live.phoneTap(&interaction, sx, sy)) {
                        // handled by Answer/Decline
                    } else if (surface == .camera and live.cameraTap(&interaction, sx, sy)) {
                        // handled by a mode selection
                    } else if (surface == .settings and live.settingsTap(&interaction, sx, sy)) {
                        // handled by a settings toggle
                    } else if (surface == .weather and live.weatherTap(&interaction, sx, sy)) {
                        // handled by adding a place or arming its alert
                    } else if (surface == .contacts and live.contactsTap(&interaction, sx, sy)) {
                        // handled by granting or revoking an agent's read of a field
                    } else if (surface == .files and live.filesTap(&interaction, sx, sy)) {
                        // handled by opening a file, or the grant refusing one that escapes it
                    } else if (surface == .calendar and live.calendarTap(&interaction, sx, sy)) {
                        // handled by booking focus on a free hour
                    } else if (surface == .browser and live.browserTap(&interaction, sx, sy)) {
                        // handled by opening a page, bookmarking, or granting the site a permission
                    } else if (surface == .tasks and live.tasksTap(&interaction, sx, sy)) {
                        // handled by completing a task
                    } else if (surface == .wallet and live.walletTap(&interaction, sx, sy)) {
                        // handled by approving the held payment
                    } else if (surface == .photos and live.photosTap(&interaction, sx, sy)) {
                        // handled by favouriting a photo
                    } else if (surface == .smarthome and live.smarthomeTap(&interaction, sx, sy)) {
                        // handled by toggling a device or approving the held unlock
                    } else if (surface == .agents) {
                        // A tap on an agent opens its detail; anything else navigates as usual.
                        if (live.agentRowAt(&host, sx, sy)) |index| {
                            interaction.open_agent = index;
                            surface = .agent_detail;
                        } else {
                            surface = navigate(surface, mx, my);
                        }
                    } else if (surface == .agent_detail) {
                        // The pause button acts on the agent; the header returns to the roster.
                        if (live.agentDetailTap(&interaction, sx, sy)) {
                            // handled
                        } else if (sy < 110) {
                            surface = .agents;
                        }
                    } else {
                        surface = navigate(surface, mx, my);
                    }
                },
                else => {},
            }
        }

        // The opening cycle plays hands-off: boot holds long enough for the mark to reveal, breathe,
        // and take its sheen, then the lock screen greets and — after a beat, or on a tap/swipe — the
        // home screen takes over. Either can be skipped by input, handled in `navigate`.
        if (surface == .boot) {
            boot_seen += 1;
            if (boot_seen > 95) surface = .lock; // ~1.6s at 60fps: just past the quick reveal and its sheen
        } else if (surface == .lock) {
            lock_seen += 1;
            if (lock_seen > 140) surface = .home; // ~2.3s: the greeting settles, then home opens
        }

        // The continuous-motion clock, for the living detail inside a surface. The shutdown screen runs
        // on its own clock from the moment it began, so the wind-down plays from its start.
        frames += 1;
        const t = if (surface == .shutdown) blk: {
            shutdown_frames += 1;
            break :blk @as(f32, @floatFromInt(shutdown_frames)) / 60.0;
        } else @as(f32, @floatFromInt(frames)) / 60.0;

        // An auto-advance (boot→lock→home) or any self-animating surface is a change that must be
        // drawn; a surface that just held still since the last pass is not.
        if (surface != prev_surface) dirty = true;
        // The camera's viewfinder follows the surface: entering the Camera app opens a real capture
        // session — which lights the privacy indicator at the frame source — and leaving it stops the
        // session, so the indicator is on exactly while the viewfinder is live and a shutter press finds
        // a real frame. On a host with no camera bound both calls are no-ops, so the camera never lights.
        if (surface != prev_surface) {
            if (surface == .camera) {
                interaction.cameraViewfinderOpen();
            } else if (prev_surface == .camera) {
                interaction.cameraViewfinderClose();
            }
        }
        prev_surface = surface;
        if (surfaceAnimates(surface)) dirty = true;

        // Paint the current surface straight to the framebuffer — an instant cut, no transition
        // frames — but only when the frame would differ, so an idle surface leaves the GPU idle.
        if (dirty) {
            try live.renderSurface(&fb, &host, surface, t, &interaction);
            _ = c.SDL_UpdateTexture(texture, null, @ptrCast(fb.pixels.ptr), @intCast(live.width * 4));
            _ = c.SDL_RenderClear(renderer);
            _ = c.SDL_RenderCopy(renderer, texture, null, null);
            c.SDL_RenderPresent(renderer);
            dirty = false;
        }
        c.SDL_Delay(16); // cap the loop at ~60 fps; input is polled every pass, so latency stays ≤ one frame
    }
    return 0;
}
