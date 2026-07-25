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
    _ = mx; // navigation uses vertical bands for now; the pointer routing is in graphics/pointer
    // Translate the window tap into the light screen's own coordinates.
    const sy = my - graphics.phone.screen_y;
    const screen_h: i32 = @intCast(graphics.phone.screen_h);
    if (current == .home) {
        if (sy >= 104 and sy <= 170) return .approval; // the command bar / active task
        if (sy >= screen_h - 110) return .store; // the dock
        if (sy >= 190 and sy <= 400) return .activity; // the in-motion list
        return .home;
    }
    if (sy < 110) return .home; // tap the header to go back home
    return switch (current) {
        .activity => .approval,
        .approval => .principals,
        .principals => .store,
        .store => .home,
        else => .home,
    };
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

    const window = c.SDL_CreateWindow(
        "Personal OS",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        W,
        H,
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

    var surface: live.Surface = .boot;
    var progress: f32 = 0.0;
    var boot_seen: u32 = 0;
    var frames: u32 = 0;
    var running = true;
    var event: c.SDL_Event = undefined;

    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) running = false;
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    const next = navigate(surface, event.button.x, event.button.y);
                    if (next != surface) {
                        surface = next;
                        progress = 0.0; // fade the new surface in
                    }
                },
                else => {},
            }
        }

        // The boot screen shows briefly, then home takes over.
        if (surface == .boot) {
            boot_seen += 1;
            if (boot_seen > 90) {
                surface = .home;
                progress = 0.0;
            }
        }

        // Advance the entrance animation and the continuous-motion clock.
        progress = @min(1.0, progress + 0.05);
        frames += 1;
        const t = @as(f32, @floatFromInt(frames)) / 60.0;

        // Paint the current surface, then fade it in with the spring easing by overlaying the desktop
        // colour at a falling alpha.
        try live.renderSurface(gpa, &fb, &host, surface, t);
        const eased = std.math.clamp(anim.springEase(progress), 0.0, 1.0);
        const overlay: u8 = @intFromFloat((1.0 - eased) * 255.0);
        if (overlay > 0) {
            graphics.paint.paint(&fb, &.{.{ .solid = .{
                .rect = .{ .x = 0, .y = 0, .w = live.width, .h = live.height },
                .colour = .{ .r = theme.desktop_bottom.red, .g = theme.desktop_bottom.green, .b = theme.desktop_bottom.blue, .a = overlay },
            } }});
        }

        _ = c.SDL_UpdateTexture(texture, null, @ptrCast(fb.pixels.ptr), @intCast(live.width * 4));
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16); // ~60 fps
    }
    return 0;
}
