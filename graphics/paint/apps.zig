//! First-party app screens, composed into rendered frames.
//!
//! These are the apps the tour opens: a phone call an agent screened and is transcribing, the message
//! threads an agent triaged, a month arranged into focus blocks, and a camera that recognises what it
//! sees on device. Each is built the same way as the shell screens — a plain composition of paint calls
//! over a framebuffer — and each shows the platform's difference: the agent is present on every surface,
//! doing work in the open, never hidden. The content is fixed demonstration material; later the same
//! layouts are driven from live app state.
//!
//! Rendered portrait at a phone's proportions.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

pub const width: u32 = 390;
pub const height: u32 = 844;

/// The app screens this module can render.
pub const App = enum { phone, messages, calendar, camera };

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

pub fn render(target: *Framebuffer, app: App) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    statusBar(target);
    switch (app) {
        .phone => renderPhone(target),
        .messages => renderMessages(target),
        .calendar => renderCalendar(target),
        .camera => renderCamera(target),
    }
}

fn statusBar(target: *Framebuffer) void {
    _ = text.draw(target, 24, 40, "9:41", 16, s(theme.text_primary));
    var indicator: u8 = 0;
    while (indicator < 3) : (indicator += 1) {
        vector.fillDisc(target, @floatFromInt(width - 24 - @as(u32, indicator) * 12), 34, 3, s(theme.text_secondary));
    }
}

fn centre(target: *Framebuffer, cx: f32, baseline: f32, str: []const u8, size: f32, colour: theme.Colour) void {
    text.drawCentred(target, cx, baseline, str, size, s(colour));
}

// --- Phone: a call an agent screened and is transcribing ---

fn renderPhone(target: *Framebuffer) void {
    const cx: f32 = @floatFromInt(width / 2);
    centre(target, cx, 150, "Clinic", 30, theme.text_primary);
    centre(target, cx, 182, "Screened by your agent", 14, theme.agent);
    centre(target, cx, 214, "0:42", 15, theme.text_secondary);

    // Agent-listening pulse.
    vector.fillDisc(target, cx, 270, 6, s(theme.agent));
    centre(target, cx, 305, "Agent is listening", 12, theme.text_secondary);

    // Live transcript card.
    const c: Rect = .{ .x = 30, .y = 340, .w = width - 60, .h = 180 };
    paint.paint(target, &.{.{ .rounded = .{ .rect = c, .radius = theme.radius_lg, .colour = s(theme.surface) } }});
    _ = text.draw(target, 48, 372, "Live transcript", 12, s(theme.text_tertiary));
    _ = text.draw(target, 48, 404, "\"Confirming your appointment", 13, s(theme.text_primary));
    _ = text.draw(target, 48, 426, "for Thursday at ten.\"", 13, s(theme.text_primary));
    _ = text.draw(target, 48, 466, "Agent: proposed a calendar hold.", 13, s(theme.agent));

    // Call controls.
    control(target, 70, 640, theme.surface_raised);
    control(target, cx - 32, 640, theme.surface_raised);
    control(target, width - 70 - 64, 640, theme.surface_raised);
    // End-call button, red.
    const end: Rect = .{ .x = @intCast(width / 2 - 40), .y = 730, .w = 80, .h = 56 };
    paint.paint(target, &.{.{ .rounded = .{ .rect = end, .radius = 24, .colour = s(theme.denied) } }});
    centre(target, @floatFromInt(width / 2), 764, "End", 14, theme.text_primary);
}

fn control(target: *Framebuffer, x: i32, y: i32, colour: theme.Colour) void {
    paint.paint(target, &.{.{ .rounded = .{ .rect = .{ .x = x, .y = y, .w = 64, .h = 64 }, .radius = 20, .colour = s(colour) } }});
}

// --- Messages: threads an agent triaged ---

const Thread = struct { name: []const u8, preview: []const u8, time: []const u8, agent: bool };

const threads = [_]Thread{
    .{ .name = "Mum", .preview = "See you Sunday!", .time = "9:20", .agent = false },
    .{ .name = "Work", .preview = "Agent negotiated the deadline", .time = "8:52", .agent = true },
    .{ .name = "Sam", .preview = "Lunch still on?", .time = "8:03", .agent = false },
    .{ .name = "Bank", .preview = "Agent flagged a charge", .time = "Tue", .agent = true },
    .{ .name = "Clinic", .preview = "Screened by your agent", .time = "Tue", .agent = true },
};

fn renderMessages(target: *Framebuffer) void {
    _ = text.draw(target, 24, 100, "Messages", 24, s(theme.text_primary));
    _ = text.draw(target, 24, 126, "Human threads stay human", 13, s(theme.text_secondary));

    var y: i32 = 156;
    for (threads) |t| {
        const c: Rect = .{ .x = 20, .y = y, .w = width - 40, .h = 72 };
        paint.paint(target, &.{.{ .rounded = .{ .rect = c, .radius = theme.radius_md, .colour = s(theme.surface) } }});
        const chip_colour = if (t.agent) theme.agent else theme.human;
        paint.paint(target, &.{.{ .rounded = .{ .rect = .{ .x = 36, .y = y + 16, .w = 40, .h = 40 }, .radius = 20, .colour = s(chip_colour) } }});
        _ = text.draw(target, 92, @floatFromInt(y + 32), t.name, 15, s(theme.text_primary));
        _ = text.draw(target, 92, @floatFromInt(y + 54), t.preview, 12, s(if (t.agent) theme.agent else theme.text_secondary));
        _ = text.draw(target, @as(f32, @floatFromInt(width)) - 40 - text.measure(t.time, 11), @floatFromInt(y + 32), t.time, 11, s(theme.text_tertiary));
        y += 82;
    }
}

// --- Calendar: a month arranged into focus blocks ---

fn renderCalendar(target: *Framebuffer) void {
    _ = text.draw(target, 24, 100, "July", 24, s(theme.text_primary));
    _ = text.draw(target, 24, 126, "Focus time, guarded by agents", 13, s(theme.text_secondary));

    const days = [_][]const u8{ "M", "T", "W", "T", "F", "S", "S" };
    const cols: u32 = 7;
    const cell: u32 = 44;
    const margin: u32 = 22;
    const grid_w = cols * cell;
    const start_x: u32 = (width - grid_w) / 2;
    _ = margin;
    // Weekday header.
    for (days, 0..) |d, i| {
        const cx = @as(f32, @floatFromInt(start_x + @as(u32, @intCast(i)) * cell + cell / 2));
        centre(target, cx, 176, d, 12, theme.text_tertiary);
    }
    // A 5x7 month grid of day numbers, with focus-block dots on a few days.
    const focus_days = [_]u8{ 8, 9, 15, 16, 22, 23 };
    var day: u8 = 1;
    var row: u32 = 0;
    while (row < 5) : (row += 1) {
        var col: u32 = 0;
        while (col < 7 and day <= 31) : (col += 1) {
            const x = start_x + col * cell;
            const y = 200 + row * (cell + 6);
            var buf: [3]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{day}) catch "";
            var is_focus = false;
            for (focus_days) |f| {
                if (f == day) is_focus = true;
            }
            if (is_focus) {
                paint.paint(target, &.{.{ .rounded = .{ .rect = .{ .x = @intCast(x + 4), .y = @intCast(y), .w = cell - 8, .h = cell - 8 }, .radius = 11, .colour = s(theme.agent) } }});
                centre(target, @floatFromInt(x + cell / 2), @floatFromInt(y + 24), label, 13, theme.base);
            } else {
                centre(target, @floatFromInt(x + cell / 2), @floatFromInt(y + 24), label, 13, theme.text_primary);
            }
            day += 1;
        }
    }

    // Legend.
    vector.fillDisc(target, 40, 560, 6, s(theme.agent));
    _ = text.draw(target, 56, 565, "Agent-arranged focus blocks", 12, s(theme.text_secondary));
}

// --- Camera: an on-device recognising viewfinder ---

fn renderCamera(target: *Framebuffer) void {
    // Viewfinder is the darker area; a subtle vignette via a large faint disc.
    paint.paint(target, &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 70, .w = width, .h = 620 }, .colour = s(theme.base) } }});

    // A recognition chip near the top.
    paint.paint(target, &.{.{ .rounded = .{ .rect = .{ .x = 100, .y = 120, .w = 190, .h = 34 }, .radius = theme.radius_pill, .colour = s(theme.surface) } }});
    vector.fillDisc(target, 120, 137, 5, s(theme.agent));
    _ = text.draw(target, 134, 142, "Recognising on device", 12, s(theme.text_primary));

    // A subject frame.
    vector.strokePolyline(target, &.{
        .{ .x = 120, .y = 320 }, .{ .x = 270, .y = 320 }, .{ .x = 270, .y = 470 }, .{ .x = 120, .y = 470 }, .{ .x = 120, .y = 320 },
    }, 2, s(theme.agent), false);
    centre(target, @floatFromInt(width / 2), 500, "Boarding pass detected", 13, theme.agent);

    // Lens modes.
    const modes = [_][]const u8{ "Photo", "Portrait", "Scan" };
    const active: usize = 2;
    var i: usize = 0;
    const total_w: u32 = 300;
    const start_x = (width - total_w) / 2;
    while (i < modes.len) : (i += 1) {
        const cx = @as(f32, @floatFromInt(start_x)) + @as(f32, @floatFromInt(total_w)) * (@as(f32, @floatFromInt(i)) + 0.5) / 3.0;
        const colour = if (i == active) theme.amber else theme.text_secondary;
        centre(target, cx, 640, modes[i], 13, colour);
    }

    // Shutter.
    vector.strokeCircle(target, @floatFromInt(width / 2), 720, 30, 4, s(theme.text_primary));
    vector.fillDisc(target, @floatFromInt(width / 2), 720, 22, s(theme.text_primary));
}

const testing = std.testing;

test "each app screen fills the frame and draws content" {
    for (std.enums.values(App)) |app| {
        var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
        defer target.deinit();
        render(&target, app);
        var whites: u32 = 0;
        var y: u32 = 20;
        while (y < 200) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                if (target.get(x, y).r > 200) whites += 1;
            }
        }
        try testing.expect(whites > 10);
    }
}

test "the calendar highlights agent focus days in the accent" {
    var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer target.deinit();
    render(&target, .calendar);
    var found = false;
    var y: u32 = 200;
    while (y < 480 and !found) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const p = target.get(x, y);
            if (p.b > p.r and p.b > 150 and p.r > 100) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}
