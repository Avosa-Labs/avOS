//! The Wallet screen, rendered bespoke and driven by real data.
//!
//! Wallet's own layout: the person's cards stacked and overlapping, each a raised tile on the soft
//! shadow so the wallet reads as a real fan of cards rather than a list. Each card shows its name, its
//! last four digits, and a chip. Every string and the per-card tint are fields of the `WalletView` the
//! shell fills from the real domain. Graphics stays app-agnostic: plain data in, pixels out.
//!
//! Rendered portrait at a phone's proportions. Bounded work: one shadow and one tile per card, drawn
//! back to front - O(cards).

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

pub const width: u32 = 390;
pub const height: u32 = 844;

/// One card in the wallet: its name, its masked number, and the two-stop tint the shell chose for it.
pub const CardCell = struct {
    name: []const u8,
    last4: []const u8,
    tint_top: theme.Colour,
    tint_bottom: theme.Colour,
};

/// Everything the Wallet screen draws, filled by the shell from the real domain.
pub const WalletView = struct {
    cards: []const CardCell,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the Wallet screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: WalletView) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));
    _ = text.draw(target, 24, 96, "Wallet", 30, s(theme.screen_text));

    const margin: i32 = 30;
    const card_w: u32 = width - 2 * @as(u32, @intCast(margin));
    const card_h: u32 = 200;
    const step: i32 = 58; // how far each card peeks above the one in front
    var y: i32 = 140;
    // Draw back to front so the front card overlaps those behind it.
    for (view.cards) |card| {
        const rect: Rect = .{ .x = margin, .y = y, .w = card_w, .h = card_h };
        paint.paint(target, &.{
            .{ .shadow = .{
                .rect = .{ .x = rect.x, .y = rect.y + theme.shadow_offset_y, .w = rect.w, .h = rect.h },
                .radius = theme.radius_lg,
                .blur = theme.shadow_blur,
                .colour = s(theme.shadow_tint),
                .alpha = theme.shadow_tint.alpha,
            } },
            .{ .rounded_vgradient = .{
                .rect = rect,
                .radius = theme.radius_lg,
                .top = s(card.tint_top),
                .bottom = s(card.tint_bottom),
            } },
            // A chip near the top-left of each card.
            .{ .rounded = .{ .rect = .{ .x = rect.x + 24, .y = y + 28, .w = 44, .h = 32 }, .radius = 6, .colour = s(theme.screen_text_soft) } },
        });
        _ = text.draw(target, @floatFromInt(rect.x + 24), @floatFromInt(y + 40), card.name, 18, s(theme.screen_text));
        // Only the front-most card shows its number in full clarity; the peeking ones show name only.
        _ = text.draw(target, @floatFromInt(rect.x + 24), @floatFromInt(y + card_h - 28), card.last4, 20, s(theme.screen_text));
        y += step;
    }
}

// --- Tests ---

const testing = std.testing;

fn sampleView() WalletView {
    return .{ .cards = &.{
        .{ .name = "Everyday", .last4 = "•••• 4821", .tint_top = theme.agent, .tint_bottom = theme.agent_soft },
        .{ .name = "Travel", .last4 = "•••• 0917", .tint_top = theme.amber, .tint_bottom = theme.surface },
        .{ .name = "Transit", .last4 = "•••• 3355", .tint_top = theme.surface_raised, .tint_bottom = theme.surface },
    } };
}

test "the wallet screen stacks its cards over the background" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    try testing.expect(target.digest() != before);
    try testing.expect(target.get(2, 2).a == 255);
    // The first card's interior has ink over the background.
    try testing.expect(target.get(195, 190).r != target.get(2, 2).r);
}

test "an empty wallet renders the header without a card or crash" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    render(&target, .{ .cards = &.{} });
    try testing.expect(target.get(2, 2).a == 255);
}
