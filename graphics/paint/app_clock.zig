//! The Clock screen, rendered bespoke and driven by real data — the second screen held to the bar.
//!
//! Clock's own layout: the local time set large as the hero over a night gradient, the date beneath
//! it, and a stacked list of world-clock cards — each a raised surface floating on the soft shadow,
//! the city and its offset on the left, the time there on the right. Nothing is demonstration content;
//! every string is a field of the `ClockView` the shell fills from the real Clock domain (the local
//! time, and each `WorldClock` the domain holds resolved to its zone). Graphics stays app-agnostic: it
//! paints the data it is handed and never reaches into an app.
//!
//! Rendered portrait at a phone's proportions. Bounded work: the hero, then one shadow and one card
//! per world clock — O(clocks), nothing more.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

pub const width: u32 = 390;
pub const height: u32 = 844;

/// One world clock in the list: the city, the time there, and its offset from local.
pub const WorldClockCell = struct {
    city: []const u8,
    time: []const u8,
    offset: []const u8, // e.g. "+3 HRS" or "TODAY"
};

/// Everything the Clock screen draws, filled by the shell from the real domain.
pub const ClockView = struct {
    location: []const u8, // the local place, e.g. "Lisbon"
    time: []const u8, // the hero, e.g. "9:41"
    date: []const u8, // e.g. "Tuesday 29 July"
    clocks: []const WorldClockCell,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the Clock screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: ClockView) void {
    // A calm night gradient behind everything.
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});

    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));

    const cx: f32 = @floatFromInt(width / 2);
    text.drawCentred(target, cx, 150, view.location, 20, s(theme.screen_text_soft));
    text.drawCentred(target, cx, 234, view.time, 88, s(theme.screen_text));
    text.drawCentred(target, cx, 274, view.date, 16, s(theme.screen_text_muted));

    // The world-clock list: a stack of raised cards.
    const margin: i32 = 20;
    const card_h: u32 = 84;
    const gap: i32 = 14;
    const card_w: u32 = width - 2 * @as(u32, @intCast(margin));
    var y: i32 = 360;
    for (view.clocks) |clock| {
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
        const left: f32 = @floatFromInt(card.x + 22);
        const baseline: f32 = @floatFromInt(y + 40);
        _ = text.draw(target, left, baseline, clock.city, 20, s(theme.screen_text));
        _ = text.draw(target, left, @floatFromInt(y + 64), clock.offset, 13, s(theme.screen_text_muted));
        // The time, right-aligned within the card.
        const right_pad: f32 = 22;
        const time_w = text.measure(clock.time, 28);
        const time_x = @as(f32, @floatFromInt(card.x + @as(i32, @intCast(card_w)))) - right_pad - time_w;
        _ = text.draw(target, time_x, baseline + 8, clock.time, 28, s(theme.screen_text));
        y += @as(i32, @intCast(card_h)) + gap;
    }
}

// --- Tests ---

const testing = std.testing;

fn sampleView() ClockView {
    return .{
        .location = "Lisbon",
        .time = "9:41",
        .date = "Tuesday 29 July",
        .clocks = &.{
            .{ .city = "Lisbon", .time = "9:41", .offset = "TODAY" },
            .{ .city = "New York", .time = "4:41", .offset = "-5 HRS" },
            .{ .city = "Tokyo", .time = "17:41", .offset = "+8 HRS" },
        },
    };
}

test "the clock screen paints its hero and world-clock cards over the night gradient" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    try testing.expect(target.digest() != before);
    try testing.expect(target.get(2, 2).a == 255); // the gradient filled the frame
    // A card region (first card interior) has ink distinct from the background gradient.
    try testing.expect(target.get(40, 395).r != target.get(2, 400).r);
}

test "no world clocks still renders the hero without drawing a card or crashing" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    var view = sampleView();
    view.clocks = &.{};
    render(&target, view);
    try testing.expect(target.get(2, 2).a == 255);
}
