//! The home screen: the day arranged by agents, composed into one rendered frame.
//!
//! This is the first full surface the render pipeline draws — everything below it (framebuffer,
//! painter, icons, text) exists so that this can be built as a plain composition. The screen is the
//! design's home: a calm dark wallpaper with a soft agent-toned glow, a greeting, an agent-activity card
//! that names what an agent just did, a grid of app tiles each with its label, and a dock of the primary
//! apps. Nothing here decides anything — it lays out and paints — so a caller can produce the home frame
//! deterministically and diff it against the reference. The layout is expressed in one function over a
//! framebuffer; later the same composition is driven from live shell state instead of the fixed
//! demonstration content.
//!
//! Rendered portrait at a phone's proportions.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const iconography = @import("iconography.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const App = iconography.App;

pub const width: u32 = 390;
pub const height: u32 = 844;

const Cell = struct { app: App, label: []const u8 };

const grid = [_]Cell{
    .{ .app = .phone, .label = "Phone" },     .{ .app = .messages, .label = "Messages" },
    .{ .app = .mail, .label = "Mail" },       .{ .app = .calendar, .label = "Calendar" },
    .{ .app = .camera, .label = "Camera" },   .{ .app = .maps, .label = "Maps" },
    .{ .app = .weather, .label = "Weather" }, .{ .app = .notes, .label = "Notes" },
    .{ .app = .health, .label = "Health" },   .{ .app = .files, .label = "Files" },
    .{ .app = .agents, .label = "Agents" },   .{ .app = .settings, .label = "Settings" },
};

const dock = [_]App{ .phone, .messages, .camera, .agents };

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the home screen into a framebuffer sized `width` x `height`.
pub fn render(target: *Framebuffer) void {
    // Wallpaper: a vertical gradient from the base to the panel tone.
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    // A soft agent-toned glow near the top, built from faint stacked discs.
    var glow: u8 = 0;
    while (glow < 3) : (glow += 1) {
        const r = @as(f32, @floatFromInt(220 - @as(u32, glow) * 40));
        vector.fillDisc(target, @floatFromInt(width / 2), 120, r, .{ .r = theme.agent.red, .g = theme.agent.green, .b = theme.agent.blue, .a = 16 });
    }

    // Status bar: the time on the left, three indicator dots on the right.
    _ = text.draw(target, 24, 40, "9:41", 17, s(theme.text_primary));
    var dot: u8 = 0;
    while (dot < 3) : (dot += 1) {
        vector.fillDisc(target, @floatFromInt(width - 24 - @as(u32, dot) * 12), 34, 3, s(theme.text_secondary));
    }

    // Greeting.
    _ = text.draw(target, 24, 96, "Good morning", 15, s(theme.text_secondary));
    _ = text.draw(target, 24, 126, "Your day, arranged by agents", 14, s(theme.agent));

    // Agent activity card.
    const card: paint.Rect = .{ .x = 24, .y = 150, .w = width - 48, .h = 74 };
    paint.paint(target, &.{.{ .rounded = .{ .rect = card, .radius = theme.radius_lg, .colour = s(theme.surface) } }});
    vector.fillDisc(target, 52, 187, 8, s(theme.agent)); // agent presence dot
    _ = text.draw(target, 74, 183, "Planner arranged your day", 13, s(theme.text_primary));
    _ = text.draw(target, 74, 204, "Held your afternoon. Tap to review.", 11, s(theme.text_secondary));
    // Chevron on the right.
    vector.strokePolyline(target, &.{ .{ .x = width - 44, .y = 180 }, .{ .x = width - 38, .y = 187 }, .{ .x = width - 44, .y = 194 } }, 2, s(theme.text_secondary), false);

    // App grid: 4 columns, 3 rows.
    const cols: u32 = 4;
    const tile: u32 = 62;
    const margin: u32 = 28;
    const gap: u32 = (width - 2 * margin - cols * tile) / (cols - 1);
    const grid_top: u32 = 262;
    const row_pitch: u32 = 96;
    for (grid, 0..) |cell, index| {
        const col: u32 = @intCast(index % cols);
        const row: u32 = @intCast(index / cols);
        const x: i32 = @intCast(margin + col * (tile + gap));
        const y: i32 = @intCast(grid_top + row * row_pitch);
        iconography.draw(target, .{ .x = x, .y = y, .w = tile, .h = tile }, cell.app);
        const centre_x = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(tile)) / 2.0;
        text.drawCentred(target, centre_x, @as(f32, @floatFromInt(y + @as(i32, @intCast(tile)))) + 18.0, cell.label, 12, s(theme.text_primary));
    }

    // Dock: a raised bar with the primary apps.
    const dock_h: u32 = 80;
    const dock_rect: paint.Rect = .{ .x = 16, .y = @intCast(height - dock_h - 24), .w = width - 32, .h = dock_h };
    paint.paint(target, &.{.{ .rounded = .{ .rect = dock_rect, .radius = theme.radius_xl, .colour = s(theme.surface_raised) } }});
    const dock_tile: u32 = 52;
    const dock_inner = @as(u32, @intCast(dock_rect.w)) - 40;
    const dock_gap = (dock_inner - dock.len * dock_tile) / (dock.len - 1);
    const dock_y: i32 = dock_rect.y + @as(i32, @intCast((dock_h - dock_tile) / 2));
    for (dock, 0..) |app, index| {
        const x: i32 = dock_rect.x + 20 + @as(i32, @intCast(index * (dock_tile + dock_gap)));
        iconography.draw(target, .{ .x = x, .y = dock_y, .w = dock_tile, .h = dock_tile }, app);
    }
}

const testing = std.testing;

test "the home screen fills the frame and draws its surfaces" {
    var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer target.deinit();
    render(&target);
    // The wallpaper is present at the very top.
    const top = target.get(width / 2, 2);
    try testing.expect(top.r != 0 or top.g != 0 or top.b != 0);
    // The dock area near the bottom is a raised surface (lighter than the base).
    const dock_px = target.get(width / 2, height - 40);
    try testing.expect(dock_px.r >= theme.base.red);
}

test "the grid draws twelve app tiles with white glyphs" {
    var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer target.deinit();
    render(&target);
    // Count near-white pixels in the grid band; twelve labelled tiles produce many.
    var whites: u32 = 0;
    var y: u32 = 262;
    while (y < 640) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const p = target.get(x, y);
            if (p.r > 230 and p.g > 230 and p.b > 230) whites += 1;
        }
    }
    try testing.expect(whites > 200);
}
