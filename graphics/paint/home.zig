//! The home screen: the day arranged by agents, on the light phone screen.
//!
//! This is the dashboard the reference design opens to — a light surface with a greeting, a command bar
//! that invites the next instruction, a live "in motion" list of what the agents are doing, the active
//! task drawn as a small flow graph, and the dock. It renders its content onto a screen framebuffer the
//! device frame has already washed light; the status bar, home indicator, and bezel are added around it
//! by the compositor. Everything here is a plain composition driven by a `Model` the live shell fills
//! from real agent state, so the frame is deterministic and the same layout serves demo and live.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const iconography = @import("iconography.zig");
const text = @import("font.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;

const w: u32 = theme.screen_w;

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Samples a palette colour at an explicit alpha, for the semi-transparent shadow and
/// veil fills — so their colour still comes from the resolved palette, only their
/// opacity is chosen at the call site.
fn sa(colour: theme.Colour, alpha: u8) fb.Rgba {
    var rgba = paint.sample(colour);
    rgba.a = alpha;
    return rgba;
}

/// One "in motion" task line on home: a titled row with a coloured presence dot.
pub const Task = struct { title: []const u8, note: []const u8, hue: theme.Colour };

/// What the home screen shows, filled from live state.
pub const Model = struct {
    greeting: []const u8 = "Good morning",
    day_line: []const u8 = "Today",
    tasks: []const Task = &.{},
    active_title: ?[]const u8 = null,
};

pub const demo = Model{
    .greeting = "Good morning, Noel",
    .day_line = "Tuesday \u{00B7} 2 agents working",
    .tasks = &.{
        .{ .title = "Booking your dentist", .note = "just now \u{00B7} spinning up agents", .hue = theme.teal },
    },
    .active_title = "Planning your Lisbon trip",
};

/// Renders the home content onto a light screen framebuffer. `t` is elapsed seconds, used for the
/// living motion (the glow dots breathe, the orb turns); pass 0 for a still frame.
pub fn render(screen: *Framebuffer, model: Model, t: f32) void {
    const pad: i32 = 22;

    // Greeting.
    _ = text.draw(screen, @floatFromInt(pad), 74, model.greeting, 19, s(theme.screen_text));
    _ = text.draw(screen, @floatFromInt(pad), 94, model.day_line, 11.5, s(theme.screen_text_muted));

    // Command bar: a white pill with the conic AI orb and a soft prompt.
    const bar: paint.Rect = .{ .x = pad, .y = 108, .w = @intCast(w - @as(u32, @intCast(pad)) * 2), .h = 50 };
    commandBar(screen, bar);
    orb(screen, @floatFromInt(bar.x + 26), @floatFromInt(bar.y + 25), 10, t);
    _ = text.draw(screen, @floatFromInt(bar.x + 46), @floatFromInt(bar.y + 30), "What should we do next?", 13, s(theme.screen_text_faint));

    // Section label.
    _ = text.draw(screen, @floatFromInt(pad + 2), 190, "IN MOTION", 11, s(theme.screen_label));
    const graph_label = "Task graph \u{203A}";
    _ = text.draw(screen, @as(f32, @floatFromInt(w)) - @as(f32, @floatFromInt(pad)) - text.measure(graph_label, 11), 190, graph_label, 11, s(theme.agent));

    // In-motion task rows.
    var y: i32 = 204;
    for (model.tasks) |task| {
        const row: paint.Rect = .{ .x = pad, .y = y, .w = @intCast(w - @as(u32, @intCast(pad)) * 2), .h = 52 };
        card(screen, row, theme.radius_xl, false);
        glowDot(screen, @floatFromInt(row.x + 22), @floatFromInt(row.y + 26), task.hue, t, 0.0);
        _ = text.draw(screen, @floatFromInt(row.x + 40), @floatFromInt(row.y + 22), task.title, 12.5, s(theme.screen_text_soft));
        _ = text.draw(screen, @floatFromInt(row.x + 40), @floatFromInt(row.y + 39), task.note, 10.5, s(theme.screen_text_muted));
        y += @as(i32, @intCast(row.h)) + 10;
    }

    // The active task: a tinted card with a small agent flow graph.
    if (model.active_title) |title| {
        const active: paint.Rect = .{ .x = pad, .y = y, .w = @intCast(w - @as(u32, @intCast(pad)) * 2), .h = 128 };
        card(screen, active, theme.radius_xl + 4, true);
        glowDot(screen, @floatFromInt(active.x + 22), @floatFromInt(active.y + 24), theme.agent, t, 0.0);
        _ = text.draw(screen, @floatFromInt(active.x + 40), @floatFromInt(active.y + 20), title, 13.5, s(theme.screen_text_soft));
        flowGraph(screen, active.x + 20, active.y + 52, active.w - 40, t);
        y += @as(i32, @intCast(active.h)) + 10;
    }

    dock(screen);
}

// --- Pieces ---

/// A white (or warm-tinted) card with the design's soft elevation.
fn card(screen: *Framebuffer, rect: paint.Rect, radius: u16, tint: bool) void {
    // A faint drop shadow: a tinted rounded rect offset below.
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = .{ .x = rect.x, .y = rect.y + 8, .w = @intCast(rect.w), .h = @intCast(rect.h) },
        .radius = radius,
        .colour = sa(theme.card_shadow, 22),
    } }});
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = rect,
        .radius = radius,
        .colour = s(if (tint) theme.screen_card_tint else theme.screen_card),
    } }});
}

/// The command bar: the white pill with the design's soft elevation and its faint violet inset border.
fn commandBar(screen: *Framebuffer, bar: paint.Rect) void {
    card(screen, bar, theme.radius_xl, false);
    // The reference's `inset 0 0 0 1.5px #9a6cff33`: a violet ring is laid down, then the white
    // interior inset over it, leaving a thin violet border around the pill.
    paint.paint(screen, &.{.{ .rounded = .{ .rect = bar, .radius = theme.radius_xl, .colour = sa(theme.agent, 52) } }});
    const inner: paint.Rect = .{ .x = bar.x + 2, .y = bar.y + 2, .w = bar.w - 4, .h = bar.h - 4 };
    paint.paint(screen, &.{.{ .rounded = .{ .rect = inner, .radius = theme.radius_xl - 2, .colour = s(theme.screen_card) } }});
}

/// The conic AI orb: a ring of tinted discs cycling coral → violet → sky → coral around the centre,
/// turning slowly, so it reads as the design's conic gradient rather than a flat dot.
fn orb(screen: *Framebuffer, cx: f32, cy: f32, r: f32, t: f32) void {
    const turn = t * 0.5;
    vector.fillDisc(screen, cx, cy, r, s(theme.agent));
    const petals = 14;
    var i: u32 = 0;
    while (i < petals) : (i += 1) {
        const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(petals));
        const a = turn + f * std.math.tau;
        vector.fillDisc(screen, cx + @cos(a) * r * 0.52, cy + @sin(a) * r * 0.52, r * 0.44, conicStop(f));
    }
    // A bright core keeps the centre reading as one orb.
    vector.fillDisc(screen, cx, cy, r * 0.4, s(theme.agent_soft));
}

/// The colour at fraction `f` around the orb's conic sweep: coral → violet → sky → coral, matching the
/// reference's `conic-gradient(from 200deg, #ff8f6b, #9a6cff, #39b7e6, #ff8f6b)`.
fn conicStop(f: f32) fb.Rgba {
    const stops = [_]theme.Colour{ theme.coral, theme.agent, theme.sky, theme.coral };
    const span = f * 3.0; // three segments between four stops
    const seg: usize = @min(2, @as(usize, @intFromFloat(span)));
    return mix(stops[seg], stops[seg + 1], span - @as(f32, @floatFromInt(seg)));
}

/// A linear blend between two palette colours; channels are read from the resolved tokens, never authored.
fn mix(a: theme.Colour, b: theme.Colour, t: f32) fb.Rgba {
    const l = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.red)) * (1.0 - l) + @as(f32, @floatFromInt(b.red)) * l),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.green)) * (1.0 - l) + @as(f32, @floatFromInt(b.green)) * l),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.blue)) * (1.0 - l) + @as(f32, @floatFromInt(b.blue)) * l),
        .a = 255,
    };
}

/// A presence dot that breathes: a coloured core inside a soft halo whose radius pulses.
fn glowDot(screen: *Framebuffer, cx: f32, cy: f32, hue: theme.Colour, t: f32, phase: f32) void {
    const pulse = 0.5 + 0.5 * @sin(t * 3.2 + phase);
    const halo = 6.0 + pulse * 2.0;
    vector.fillDisc(screen, cx, cy, halo, .{ .r = hue.red, .g = hue.green, .b = hue.blue, .a = 40 });
    vector.fillDisc(screen, cx, cy, 4.5, s(hue));
}

/// A tiny agent task graph: a person node, an agent node that spins, and three branch endpoints joined
/// by soft connector lines — the shape the design draws inside the active task.
fn flowGraph(screen: *Framebuffer, x: i32, y: i32, width: u32, t: f32) void {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const line = s(theme.screen_line);
    const a_x = fx + @as(f32, @floatFromInt(width)) * 0.36;
    const ends_x = fx + @as(f32, @floatFromInt(width)) * 0.78;
    // Connectors.
    vector.strokePolyline(screen, &.{ .{ .x = fx + 10, .y = fy + 24 }, .{ .x = a_x, .y = fy + 24 } }, 2, line, false);
    var b: u8 = 0;
    while (b < 3) : (b += 1) {
        const ey = fy + 8 + @as(f32, @floatFromInt(b)) * 16;
        vector.strokePolyline(screen, &.{ .{ .x = a_x, .y = fy + 24 }, .{ .x = (a_x + ends_x) / 2, .y = ey }, .{ .x = ends_x, .y = ey } }, 2, line, false);
        vector.fillDisc(screen, ends_x, ey, 7, s(theme.screen_card));
        vector.strokeCircle(screen, ends_x, ey, 7, 1.5, s(theme.agent_soft));
    }
    // Person node (warm) and the spinning agent node.
    vector.fillDisc(screen, fx + 10, fy + 24, 9, s(theme.coral));
    orb(screen, a_x, fy + 24, 9, t);
}

/// The dock: a translucent bar carrying the primary apps.
pub const dock_apps = [_]iconography.App{ .phone, .messages, .camera, .agents };

fn dock(screen: *Framebuffer) void {
    const dh: u32 = 76;
    const rect: paint.Rect = .{ .x = 16, .y = @intCast(theme.screen_h - dh - 26), .w = w - 32, .h = dh };
    // A dark, translucent floating bar — the design's dock, distinct from the light screen so the
    // coloured app tiles read against it.
    paint.paint(screen, &.{.{ .rounded = .{ .rect = rect, .radius = theme.radius_xl + 4, .colour = sa(theme.base, 210) } }});
    const tile: u32 = 52;
    const inner = @as(u32, @intCast(rect.w)) - 44;
    const gap = (inner - dock_apps.len * tile) / (dock_apps.len - 1);
    const iy: i32 = rect.y + @as(i32, @intCast((dh - tile) / 2));
    for (dock_apps, 0..) |app, i| {
        const ix: i32 = rect.x + 22 + @as(i32, @intCast(i * (tile + gap)));
        iconography.draw(screen, .{ .x = ix, .y = iy, .w = tile, .h = tile }, app);
    }
}

const testing = std.testing;

test "home renders white cards on a light screen" {
    var screen = try Framebuffer.init(testing.allocator, theme.screen_w, theme.screen_h, s(theme.screen_top));
    defer screen.deinit();
    render(&screen, demo, 0.0);
    // The command-bar area holds white card pixels over the light wash.
    var whites: u32 = 0;
    var yy: u32 = 110;
    while (yy < 156) : (yy += 1) {
        var xx: u32 = 24;
        while (xx < theme.screen_w - 24) : (xx += 1) {
            const p = screen.get(xx, yy);
            if (p.r > 250 and p.g > 250 and p.b > 250) whites += 1;
        }
    }
    try testing.expect(whites > 300);
}

test "home text is dark on the light screen" {
    var screen = try Framebuffer.init(testing.allocator, theme.screen_w, theme.screen_h, s(theme.screen_top));
    defer screen.deinit();
    render(&screen, demo, 0.0);
    // Somewhere in the greeting band there are near-black text pixels.
    var darks: u32 = 0;
    var yy: u32 = 60;
    while (yy < 96) : (yy += 1) {
        var xx: u32 = 22;
        while (xx < 260) : (xx += 1) {
            const p = screen.get(xx, yy);
            if (p.r < 0x50 and p.g < 0x50 and p.b < 0x60) darks += 1;
        }
    }
    try testing.expect(darks > 20);
}
