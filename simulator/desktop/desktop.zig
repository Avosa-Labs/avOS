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
const live = @import("live_render");
const graphics = @import("graphics");
const design = @import("design");

const c = @import("sdl.zig");

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

    // A tap in the header returns home from any sub-surface.
    if (current != .home and sy < 110) return .home;

    if (current == .home) {
        // The dock: hit-test each app tile so a tap opens that app, not a band.
        if (dockApp(sx, sy, screen_w, screen_h)) |app| return app;
        if (sy >= 104 and sy <= 184) return .approval; // the command bar / active task
        if (sy >= 200 and sy <= 440) return .activity; // the in-motion list
        return .home;
    }

    // On an app or a sub-surface, tapping the body returns home.
    return .home;
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

/// Blends `src` over `dst` at `alpha` (0..255) across the whole framebuffer — the per-pixel dissolve
/// that carries a surface change from the old frame to the new one. Both frames are opaque, so alpha
/// stays 255 and only the colour channels mix.
fn crossfade(dst: *Framebuffer, src: *const Framebuffer, alpha: u8) void {
    const a: u32 = alpha;
    const inv: u32 = 255 - a;
    var i: usize = 0;
    while (i < dst.pixels.len) : (i += 1) {
        dst.pixels[i] = @intCast((@as(u32, dst.pixels[i]) * inv + @as(u32, src.pixels[i]) * a) / 255);
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var host: live.Host = undefined;
    try live.runScenario(&host, gpa);
    defer host.deinit();

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
    // A snapshot of the frame on screen when a surface change begins, so the change crossfades from the
    // old surface to the new one instead of flashing through the dark desktop colour.
    var prev = try Framebuffer.init(gpa, live.width, live.height, .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = 255 });
    defer prev.deinit();

    var surface: live.Surface = .boot;
    var displayed: live.Surface = .boot; // the surface the framebuffer currently holds
    var transitioning = false;
    var progress: f32 = 0.0;
    var boot_seen: u32 = 0;
    var lock_seen: u32 = 0;
    var frames: u32 = 0;
    var running = true;
    var event: c.SDL_Event = undefined;

    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    const key = event.key.keysym.sym;
                    if (key == c.SDLK_ESCAPE) running = false;
                    // Up / space / return is the "swipe up to open": it skips boot to the lock screen
                    // and unlocks the lock screen to home. Confined to the opening cycle so it never
                    // stray-navigates an app surface.
                    if ((surface == .boot or surface == .lock) and
                        (key == c.SDLK_UP or key == c.SDLK_SPACE or key == c.SDLK_RETURN))
                    {
                        surface = if (surface == .boot) .lock else .home;
                        progress = 0.0;
                    }
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    // The click arrives in window coordinates; map it back to the
                    // device's full-resolution coordinates the surfaces are laid out in.
                    const mx: i32 = @intFromFloat(@as(f32, @floatFromInt(event.button.x)) / fit);
                    const my: i32 = @intFromFloat(@as(f32, @floatFromInt(event.button.y)) / fit);
                    const next = navigate(surface, mx, my);
                    if (next != surface) {
                        surface = next;
                        progress = 0.0; // fade the new surface in
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
            if (boot_seen > 170) { // ~2.8s at 60fps: past the 1.6s reveal and the 2.55s sheen
                surface = .lock;
                progress = 0.0;
            }
        } else if (surface == .lock) {
            lock_seen += 1;
            if (lock_seen > 210) { // ~3.5s: the greeting settles, then home opens
                surface = .home;
                progress = 0.0;
            }
        }

        // A surface change captures the frame currently on screen, so the new surface can crossfade over
        // it. The capture happens before the framebuffer is repainted, while it still holds the old view.
        if (surface != displayed) {
            @memcpy(prev.pixels, fb.pixels);
            transitioning = true;
            progress = 0.0;
        }

        // Advance the entrance animation and the continuous-motion clock.
        progress = @min(1.0, progress + 0.06);
        frames += 1;
        const t = @as(f32, @floatFromInt(frames)) / 60.0;

        // Paint the current surface, then, mid-transition, crossfade the captured previous frame out over
        // it with the spring easing — a seamless dissolve, never a flash to the desktop colour.
        try live.renderSurface(gpa, &fb, &host, surface, t);
        if (transitioning) {
            const eased = std.math.clamp(anim.springEase(progress), 0.0, 1.0);
            const carry: u8 = @intFromFloat((1.0 - eased) * 255.0); // how much of the previous frame remains
            if (carry == 0) {
                transitioning = false;
            } else {
                crossfade(&fb, &prev, carry);
            }
        }
        displayed = surface;

        _ = c.SDL_UpdateTexture(texture, null, @ptrCast(fb.pixels.ptr), @intCast(live.width * 4));
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16); // ~60 fps
    }
    return 0;
}
