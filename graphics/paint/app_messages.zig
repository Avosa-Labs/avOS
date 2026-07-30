//! The Messages screen, rendered bespoke and driven by real data.
//!
//! Messages' own layout: a list of conversation rows, each a raised card on the soft shadow with a
//! tinted avatar, the correspondent's name, a snippet of the last message, its time, and - the point
//! of this platform - a small agent mark when an agent triaged the thread, so the person sees the
//! agent's work in the open. Every string, tint, and the handled flag are fields of the
//! `MessagesView` the shell fills from the real domain. Graphics stays app-agnostic.
//!
//! Rendered portrait at a phone's proportions. Bounded: one shadow and one card per thread - O(threads).

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

/// One conversation row: who it is with, the last snippet, its time, the avatar tint, and whether an
/// agent handled (triaged, drafted, screened) the thread.
pub const Thread = struct {
    name: []const u8,
    snippet: []const u8,
    time: []const u8,
    tint: theme.Colour,
    agent_handled: bool,
};

/// Everything the Messages screen draws, filled by the shell from the real domain.
pub const MessagesView = struct {
    threads: []const Thread,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the Messages screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: MessagesView) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));
    _ = text.draw(target, 24, 100, "Messages", 30, s(theme.screen_text));

    const margin: i32 = 16;
    const card_w: u32 = width - 2 * @as(u32, @intCast(margin));
    const card_h: u32 = 84;
    const gap: i32 = 10;
    var y: i32 = 132;
    for (view.threads) |thread| {
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
        // Tinted avatar disc with the correspondent's initial.
        const avatar_cx: f32 = @floatFromInt(card.x + 44);
        const avatar_cy: f32 = @floatFromInt(y + @as(i32, @intCast(card_h / 2)));
        vector.fillDisc(target, avatar_cx, avatar_cy, 24, s(thread.tint));
        if (thread.name.len > 0) {
            text.drawCentred(target, avatar_cx, avatar_cy + 6, thread.name[0..1], 18, s(theme.screen_text));
        }
        // Name and snippet stacked to the right of the avatar.
        const tx: f32 = @floatFromInt(card.x + 84);
        _ = text.draw(target, tx, @floatFromInt(y + 34), thread.name, 17, s(theme.screen_text));
        _ = text.draw(target, tx, @floatFromInt(y + 58), thread.snippet, 13, s(theme.screen_text_muted));
        // Time, right-aligned; and an agent mark below it when an agent handled the thread.
        const time_w = text.measure(thread.time, 12);
        const right: f32 = @floatFromInt(card.x + @as(i32, @intCast(card_w)) - 18);
        _ = text.draw(target, right - time_w, @floatFromInt(y + 32), thread.time, 12, s(theme.screen_text_muted));
        if (thread.agent_handled) {
            vector.fillDisc(target, right - 4, @floatFromInt(y + 56), 5, s(theme.agent));
        }
        y += @as(i32, @intCast(card_h)) + gap;
    }
}

// --- Tests ---

const testing = std.testing;

fn sampleView() MessagesView {
    return .{ .threads = &.{
        .{ .name = "Marco Dias", .snippet = "Agent drafted a reply for you", .time = "9:32", .tint = theme.agent, .agent_handled = true },
        .{ .name = "Bank", .snippet = "Screened: likely a statement", .time = "8:10", .tint = theme.amber, .agent_handled = true },
        .{ .name = "Ana", .snippet = "See you at the studio", .time = "Yst", .tint = theme.surface_raised, .agent_handled = false },
    } };
}

test "the messages screen paints its rows and marks the agent-handled ones" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    try testing.expect(target.digest() != before);
    try testing.expect(target.get(2, 2).a == 255);
    // The first card's interior has ink over the background.
    try testing.expect(target.get(60, 160).r != target.get(2, 300).r);
}

test "no threads renders the header without a row or crash" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    render(&target, .{ .threads = &.{} });
    try testing.expect(target.get(2, 2).a == 255);
}
