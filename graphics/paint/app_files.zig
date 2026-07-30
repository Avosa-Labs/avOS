//! The Files screen, rendered bespoke and driven by real data.
//!
//! Files' own layout: the current folder name, then a list of entry rows, each a raised card with a
//! kind glyph tile (folder or a file extension), the name, and a detail line. Every string and kind is
//! a field of the `FilesView` the shell fills from the real domain, confined to the grant. Graphics
//! stays app-agnostic.
//!
//! Rendered portrait at a phone's proportions. Bounded: one card per entry - O(entries).

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

pub const width: u32 = 390;
pub const height: u32 = 844;

/// One entry row: its name, a detail line (size or item count), the short kind label the tile shows
/// (FLD, TXT, JPG), and whether it is a folder (drawn in the accent).
pub const Entry = struct {
    name: []const u8,
    detail: []const u8,
    kind: []const u8,
    is_folder: bool,
};

/// Everything the Files screen draws, filled by the shell from the real domain.
pub const FilesView = struct {
    folder: []const u8,
    entries: []const Entry,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the Files screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: FilesView) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));
    _ = text.draw(target, 24, 100, view.folder, 30, s(theme.screen_text));

    const margin: i32 = 16;
    const card_w: u32 = width - 2 * @as(u32, @intCast(margin));
    const card_h: u32 = 68;
    const gap: i32 = 10;
    var y: i32 = 136;
    for (view.entries) |entry| {
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
        // The kind tile: a rounded square, accent for a folder, neutral for a file.
        const tile_top = if (entry.is_folder) theme.agent else theme.surface_raised;
        const tile_bottom = if (entry.is_folder) theme.agent_soft else theme.surface;
        const tile: Rect = .{ .x = card.x + 16, .y = y + 16, .w = 36, .h = 36 };
        paint.paint(target, &.{.{ .rounded_vgradient = .{ .rect = tile, .radius = theme.radius_sm, .top = s(tile_top), .bottom = s(tile_bottom) } }});
        text.drawCentred(target, @floatFromInt(tile.x + 18), @floatFromInt(tile.y + 24), entry.kind, 11, s(theme.screen_text));
        const tx: f32 = @floatFromInt(card.x + 66);
        _ = text.draw(target, tx, @floatFromInt(y + 32), entry.name, 16, s(theme.screen_text));
        _ = text.draw(target, tx, @floatFromInt(y + 52), entry.detail, 12, s(theme.screen_text_muted));
        y += @as(i32, @intCast(card_h)) + gap;
    }
}

// --- Tests ---

const testing = std.testing;

fn sampleView() FilesView {
    return .{ .folder = "Documents", .entries = &.{
        .{ .name = "Trips", .detail = "12 items", .kind = "FLD", .is_folder = true },
        .{ .name = "report.txt", .detail = "24 KB", .kind = "TXT", .is_folder = false },
        .{ .name = "lisbon.jpg", .detail = "1.8 MB", .kind = "JPG", .is_folder = false },
    } };
}

test "the files screen paints the folder name and entry cards" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    try testing.expect(target.digest() != before);
    try testing.expect(target.get(2, 2).a == 255);
    try testing.expect(target.get(34, 160).r != target.get(2, 400).r); // first tile has ink
}

test "an empty folder renders the name without a card or crash" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    render(&target, .{ .folder = "Empty", .entries = &.{} });
    try testing.expect(target.get(2, 2).a == 255);
}
