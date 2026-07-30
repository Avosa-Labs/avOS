//! The Tasks screen, rendered bespoke and driven by real data.
//!
//! Tasks' own layout: a heading with the count still open, then a list of task rows, each a raised card
//! with a checkbox (filled when done), the title, and a due label. A task an agent added or completed
//! carries a small agent mark. Every string and flag is a field of the `TasksView` the shell fills from
//! the real domain. Graphics stays app-agnostic.
//!
//! Rendered portrait at a phone's proportions. Bounded: one card per task - O(tasks).

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

/// One task row: its title, a due label, whether it is done, and whether an agent touched it.
pub const Task = struct {
    title: []const u8,
    due: []const u8,
    done: bool,
    agent_added: bool,
};

/// Everything the Tasks screen draws, filled by the shell from the real domain.
pub const TasksView = struct {
    heading: []const u8, // e.g. "Today" or "4 open"
    tasks: []const Task,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the Tasks screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: TasksView) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));
    _ = text.draw(target, 24, 100, "Tasks", 30, s(theme.screen_text));
    _ = text.draw(target, 24, 130, view.heading, 15, s(theme.screen_text_muted));

    const margin: i32 = 16;
    const card_w: u32 = width - 2 * @as(u32, @intCast(margin));
    const card_h: u32 = 66;
    const gap: i32 = 10;
    var y: i32 = 160;
    for (view.tasks) |task| {
        const card: Rect = .{ .x = margin, .y = y, .w = card_w, .h = card_h };
        paint.paint(target, &.{
            .{ .shadow = .{
                .rect = .{ .x = card.x, .y = card.y + theme.shadow_offset_y, .w = card.w, .h = card.h },
                .radius = theme.radius_lg,
                .blur = theme.shadow_blur,
                .colour = s(theme.shadow_tint),
                .alpha = theme.shadow_tint.alpha,
            } },
            .{ .rounded_vgradient = .{
                .rect = card,
                .radius = theme.radius_lg,
                .top = s(theme.surface_raised),
                .bottom = s(theme.surface),
            } },
        });
        // Checkbox: a ring, filled with the accent and a tick when done.
        const box_cx: f32 = @floatFromInt(card.x + 34);
        const box_cy: f32 = @floatFromInt(y + @as(i32, @intCast(card_h / 2)));
        if (task.done) {
            vector.fillDisc(target, box_cx, box_cy, 13, s(theme.agent));
            vector.strokePolyline(target, &.{
                .{ .x = box_cx - 6, .y = box_cy }, .{ .x = box_cx - 1, .y = box_cy + 5 }, .{ .x = box_cx + 7, .y = box_cy - 5 },
            }, 2.5, s(theme.base), false);
        } else {
            vector.strokeCircle(target, box_cx, box_cy, 13, 2, s(theme.screen_text_muted));
        }
        const tx: f32 = @floatFromInt(card.x + 64);
        const title_colour = if (task.done) theme.screen_text_muted else theme.screen_text;
        _ = text.draw(target, tx, @floatFromInt(y + 30), task.title, 16, s(title_colour));
        _ = text.draw(target, tx, @floatFromInt(y + 50), task.due, 12, s(theme.screen_text_muted));
        if (task.agent_added) {
            vector.fillDisc(target, @floatFromInt(card.x + @as(i32, @intCast(card_w)) - 22), @floatFromInt(y + 24), 5, s(theme.agent));
        }
        y += @as(i32, @intCast(card_h)) + gap;
    }
}

// --- Tests ---

const testing = std.testing;

fn sampleView() TasksView {
    return .{ .heading = "Today", .tasks = &.{
        .{ .title = "Confirm the studio booking", .due = "5pm", .done = false, .agent_added = true },
        .{ .title = "Pay the electricity bill", .due = "Overdue", .done = false, .agent_added = false },
        .{ .title = "Reply to Marco", .due = "Done", .done = true, .agent_added = true },
    } };
}

test "the tasks screen paints its cards, checked and unchecked" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    try testing.expect(target.digest() != before);
    try testing.expect(target.get(2, 2).a == 255);
    try testing.expect(target.get(50, 190).r != target.get(2, 400).r); // first card region has ink
}

test "no tasks renders the header without a card or crash" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    render(&target, .{ .heading = "All clear", .tasks = &.{} });
    try testing.expect(target.get(2, 2).a == 255);
}
