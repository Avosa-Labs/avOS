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
    /// Whether the on-device assistant mind is loaded. When it is not, the command bar says so
    /// honestly rather than inviting a question it cannot answer.
    assistant_online: bool = false,
    /// The assistant's last reply, shown in the command bar when present. Untrusted mind output.
    assistant_reply: []const u8 = "",
    /// What the person is currently typing into the command bar, shown as they type.
    assistant_prompt: []const u8 = "",
};

pub const demo = Model{
    .greeting = "Good morning, Noel",
    .day_line = "Tuesday \u{00B7} 2 agents working",
    .tasks = &.{
        .{ .title = "Booking your dentist", .note = "just now \u{00B7} spinning up agents", .hue = theme.teal },
    },
    .active_title = "Planning your Lisbon trip",
};

/// The reference lays the home out on a 326px-wide device; this screen is wider, so every reference
/// dimension — type size, padding, card height — is taken times this factor to keep the proportions,
/// and the weight of a heading or prompt is pinned rather than inferred, so the screen reads at the
/// reference's scale and typographic weight rather than a size smaller.
const ui: f32 = @as(f32, @floatFromInt(theme.screen_w)) / 326.0;

fn u(reference_px: f32) f32 {
    return reference_px * ui;
}

/// The content inset, at the reference's proportion — shared by the render body and the app grid.
const pad_home: i32 = @intFromFloat(u(16.0));

/// Renders the home content onto a light screen framebuffer. `t` is elapsed seconds, used for the
/// living motion (the glow dots breathe, the orb turns); pass 0 for a still frame.
pub fn render(screen: *Framebuffer, model: Model, t: f32) void {
    const pad: i32 = @intFromFloat(u(16));

    // Greeting: the heading in semibold, the day line in the muted regular weight.
    _ = text.draw(screen, @floatFromInt(pad), u(60), model.greeting, u(19), s(theme.screen_text));
    _ = text.drawWeighted(screen, @floatFromInt(pad), u(77), model.day_line, u(11.5), s(theme.screen_text_muted), .regular);

    // Command bar: a white pill with the conic AI orb and a soft, light prompt.
    const bar: paint.Rect = .{ .x = pad, .y = @intFromFloat(u(90)), .w = @intCast(w - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(u(48)) };
    const bar_mid: f32 = @as(f32, @floatFromInt(bar.y)) + @as(f32, @floatFromInt(bar.h)) / 2.0;
    commandBar(screen, bar);
    orb(screen, @as(f32, @floatFromInt(bar.x)) + u(24), bar_mid, u(10), t);
    // The command bar reflects the real assistant: its last reply if it answered, an honest offline
    // note when no mind is loaded, or the prompt when the mind is ready and idle.
    const bar_text_x = @as(f32, @floatFromInt(bar.x)) + u(44);
    const bar_edge = @as(f32, @floatFromInt(bar.x + @as(i32, @intCast(bar.w)))) - u(16);
    if (model.assistant_prompt.len > 0) {
        _ = text.drawClipped(screen, bar_text_x, bar_mid + u(4.5), model.assistant_prompt, u(13), s(theme.screen_text), bar_edge);
    } else if (model.assistant_reply.len > 0) {
        _ = text.drawClipped(screen, bar_text_x, bar_mid + u(4.5), model.assistant_reply, u(13), s(theme.screen_text_soft), bar_edge);
    } else if (!model.assistant_online) {
        _ = text.drawWeighted(screen, bar_text_x, bar_mid + u(4.5), "Assistant offline \u{00B7} load a model", u(12.5), s(theme.screen_text_faint), .regular);
    } else {
        _ = text.drawWeighted(screen, bar_text_x, bar_mid + u(4.5), "What should we do next?", u(13), s(theme.screen_text_faint), .regular);
    }

    // Section label and the task-graph link, both pinned to the reference's heavier weights.
    const label_y = u(90) + u(48) + u(24);
    _ = text.drawWeighted(screen, @floatFromInt(pad), label_y, "IN MOTION", u(11), s(theme.screen_label), .semibold);
    const graph_label = "Task graph \u{203A}";
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(w)) - @as(f32, @floatFromInt(pad)) - text.measureWeighted(graph_label, u(11), .semibold), label_y, graph_label, u(11), s(theme.agent), .semibold);

    // In-motion task rows.
    var y: i32 = @intFromFloat(label_y + u(12));
    const row_h: i32 = @intFromFloat(u(50));
    for (model.tasks) |task| {
        const row: paint.Rect = .{ .x = pad, .y = y, .w = @intCast(w - @as(u32, @intCast(pad)) * 2), .h = @intCast(row_h) };
        card(screen, row, theme.radius_xl, false);
        glowDot(screen, @as(f32, @floatFromInt(row.x)) + u(20), @as(f32, @floatFromInt(row.y)) + @as(f32, @floatFromInt(row.h)) / 2.0, task.hue, t, 0.0);
        _ = text.draw(screen, @as(f32, @floatFromInt(row.x)) + u(38), @as(f32, @floatFromInt(row.y)) + u(21), task.title, u(12.5), s(theme.screen_text_soft));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(row.x)) + u(38), @as(f32, @floatFromInt(row.y)) + u(37), task.note, u(10.5), s(theme.screen_text_muted), .regular);
        y += row_h + @as(i32, @intFromFloat(u(10)));
    }

    // The active task: a tinted card with a small agent flow graph.
    if (model.active_title) |title| {
        const active: paint.Rect = .{ .x = pad, .y = y, .w = @intCast(w - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(u(122)) };
        card(screen, active, theme.radius_xl + 4, true);
        glowDot(screen, @as(f32, @floatFromInt(active.x)) + u(20), @as(f32, @floatFromInt(active.y)) + u(24), theme.agent, t, 0.0);
        _ = text.draw(screen, @as(f32, @floatFromInt(active.x)) + u(38), @as(f32, @floatFromInt(active.y)) + u(20), title, u(12), s(theme.screen_text_soft));
        flowGraph(screen, active.x + @as(i32, @intFromFloat(u(18))), active.y + @as(i32, @intFromFloat(u(50))), active.w - @as(u32, @intFromFloat(u(36))), t);
        y += @as(i32, @intCast(active.h)) + @as(i32, @intFromFloat(u(10)));
    }

    appGrid(screen, gridTop(model));
    dock(screen);
}

/// The apps shown on the home screen — those that fit above the dock. The rest live in the full app
/// list reached by "All apps" / a swipe left. Phone, Messages, Camera and Agents are already in the dock.
pub const grid_apps = [_]iconography.App{ .settings, .calendar, .files, .contacts, .weather, .browser, .calculator, .store };

/// The y at which the "Your apps" section begins, derived from the same layout the body draws, so a
/// hit-test lands on exactly what is shown. Kept in step with `render`'s vertical accumulation.
pub fn gridTop(model: Model) i32 {
    const label_y = u(90) + u(48) + u(24);
    var y: f32 = label_y + u(12);
    for (model.tasks) |_| y += u(50) + u(10);
    if (model.active_title != null) y += u(122) + u(10);
    return @intFromFloat(y + u(6));
}

/// The grid tile (app) at a screen-local point, or null. The hit region is the whole cell down through
/// the label, so tapping a tile or its name opens the app.
pub fn gridTileAt(model: Model, x: i32, y: i32) ?iconography.App {
    const cols: usize = 4;
    const content_w = @as(f32, @floatFromInt(w)) - 2.0 * @as(f32, @floatFromInt(pad_home));
    const gap_x = u(8);
    const cell_w = (content_w - gap_x * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const tile = u(54);
    const grid_top = @as(f32, @floatFromInt(gridTop(model))) + u(16);
    const row_h = u(74);
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    for (grid_apps, 0..) |app, i| {
        const col: usize = i % cols;
        const row: usize = i / cols;
        const cell_x = @as(f32, @floatFromInt(pad_home)) + @as(f32, @floatFromInt(col)) * (cell_w + gap_x);
        const tile_y = grid_top + @as(f32, @floatFromInt(row)) * row_h;
        if (fx >= cell_x and fx <= cell_x + cell_w and fy >= tile_y and fy <= tile_y + tile + u(18)) return app;
    }
    return null;
}

/// Whether a screen-local point falls on the "All apps" link in the grid header.
pub fn allAppsAt(model: Model, x: i32, y: i32) bool {
    const top: f32 = @floatFromInt(gridTop(model));
    const fy: f32 = @floatFromInt(y);
    if (fy < top - u(8) or fy > top + u(14)) return false;
    return @as(f32, @floatFromInt(x)) > @as(f32, @floatFromInt(w)) * 0.58;
}

/// A short label for an app tile.
pub fn appName(app: iconography.App) []const u8 {
    return switch (app) {
        .phone => "Phone",
        .messages => "Messages",
        .calendar => "Calendar",
        .camera => "Camera",
        .health => "Health",
        .agents => "Agents",
        .files => "Files",
        .settings => "Settings",
        .contacts => "Contacts",
        .browser => "Browser",
        .calculator => "Calculator",
        .store => "Store",
        .weather => "Weather",
        .mail => "Mail",
        .notes => "Notes",
        .maps => "Maps",
        .tasks => "Tasks",
        .music => "Music",
        .wallet => "Wallet",
        .photos => "Photos",
        .clock => "Clock",
        .home => "Home",
    };
}

/// The "Your apps" section: a label with an "All apps" link, then a four-column grid of app tiles with
/// their names — the reference's home app grid, drawn with the delivered icons.
fn appGrid(screen: *Framebuffer, top: i32) void {
    const ft: f32 = @floatFromInt(top);
    _ = text.drawWeighted(screen, @floatFromInt(pad_home), ft, "YOUR APPS", u(11), s(theme.screen_label), .semibold);
    const link = "All apps \u{203A}";
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(w)) - @as(f32, @floatFromInt(pad_home)) - text.measureWeighted(link, u(11), .semibold), ft, link, u(11), s(theme.agent), .semibold);

    const cols: usize = 4;
    const content_w = @as(f32, @floatFromInt(w)) - 2.0 * @as(f32, @floatFromInt(pad_home));
    const gap_x = u(8);
    const cell_w = (content_w - gap_x * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const tile = u(54);
    const grid_top = ft + u(16);
    const row_h = u(74);

    for (grid_apps, 0..) |app, i| {
        const col: usize = i % cols;
        const row: usize = i / cols;
        const cell_x = @as(f32, @floatFromInt(pad_home)) + @as(f32, @floatFromInt(col)) * (cell_w + gap_x);
        const tile_x = cell_x + (cell_w - tile) / 2.0;
        const tile_y = grid_top + @as(f32, @floatFromInt(row)) * row_h;
        iconography.draw(screen, .{ .x = @intFromFloat(tile_x), .y = @intFromFloat(tile_y), .w = @intFromFloat(tile), .h = @intFromFloat(tile) }, app);
        text.drawCentred(screen, cell_x + cell_w / 2.0, tile_y + tile + u(13), appName(app), u(9.5), s(theme.screen_text_muted));
    }
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
    const halo = u(6.0) + pulse * u(2.0);
    vector.fillDisc(screen, cx, cy, halo, .{ .r = hue.red, .g = hue.green, .b = hue.blue, .a = 40 });
    vector.fillDisc(screen, cx, cy, u(4.5), s(hue));
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
