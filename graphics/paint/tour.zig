//! The tour: the whole system on one contact sheet, boot to rest.
//!
//! Every screen the render layer can draw, laid out together as a storyboard — the boot fade, the home
//! screen, the agent-native shell surfaces, the apps, and the rest fade. It is how the platform is seen
//! whole rather than one screen at a time: each frame is rendered at full size and then area-downsampled
//! into a labelled thumbnail, so the sheet is a faithful reduction of the real frames, not a separate
//! mock. The same render functions drive both the individual screens and this overview, so the tour can
//! never drift from what the device actually shows.
//!
//! On a device this sequence plays as animated transitions; here it is a single image so the whole can
//! be taken in at once.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const text = @import("text.zig");
const home = @import("home.zig");
const screens = @import("screens.zig");
const apps = @import("apps.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;

const screen_w: u32 = 390;
const screen_h: u32 = 844;

/// One frame of the tour: a label and a function that renders it into a full-size framebuffer.
const Frame = struct { label: []const u8, render: *const fn (*Framebuffer) void };

fn renderBoot(target: *Framebuffer) void {
    paint.paint(target, &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h }, .colour = paint.sample(theme.base) } }});
    // A soft agent glow rising from the centre — the system greeting you before you ask.
    var g: u8 = 0;
    while (g < 4) : (g += 1) {
        const r = @as(f32, @floatFromInt(260 - @as(u32, g) * 50));
        vector.fillDisc(target, @floatFromInt(screen_w / 2), @floatFromInt(screen_h / 2), r, .{ .r = theme.agent.red, .g = theme.agent.green, .b = theme.agent.blue, .a = 18 });
    }
    text.drawCentred(target, @floatFromInt(screen_w / 2), @floatFromInt(screen_h / 2 + 6), "Starting your world", 16, paint.sample(theme.text_primary));
}

fn renderRest(target: *Framebuffer) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h },
        .top = paint.sample(theme.panel),
        .bottom = paint.sample(theme.base),
    } }});
    text.drawCentred(target, @floatFromInt(screen_w / 2), @floatFromInt(screen_h / 2 - 8), "Everything handled.", 18, paint.sample(theme.text_primary));
    text.drawCentred(target, @floatFromInt(screen_w / 2), @floatFromInt(screen_h / 2 + 24), "Hello, world.", 14, paint.sample(theme.text_secondary));
}

fn renderHome(target: *Framebuffer) void {
    home.render(target);
}
fn renderApproval(target: *Framebuffer) void {
    screens.render(target, .approval);
}
fn renderLedger(target: *Framebuffer) void {
    screens.render(target, .ledger);
}
fn renderPrincipals(target: *Framebuffer) void {
    screens.render(target, .principals);
}
fn renderSettings(target: *Framebuffer) void {
    screens.render(target, .settings);
}
fn renderPhone(target: *Framebuffer) void {
    apps.render(target, .phone);
}
fn renderMessages(target: *Framebuffer) void {
    apps.render(target, .messages);
}
fn renderCalendar(target: *Framebuffer) void {
    apps.render(target, .calendar);
}
fn renderCamera(target: *Framebuffer) void {
    apps.render(target, .camera);
}

const frames = [_]Frame{
    .{ .label = "Boot", .render = renderBoot },
    .{ .label = "Home", .render = renderHome },
    .{ .label = "Approval", .render = renderApproval },
    .{ .label = "Activity", .render = renderLedger },
    .{ .label = "Principals", .render = renderPrincipals },
    .{ .label = "Settings", .render = renderSettings },
    .{ .label = "Phone", .render = renderPhone },
    .{ .label = "Messages", .render = renderMessages },
    .{ .label = "Calendar", .render = renderCalendar },
    .{ .label = "Camera", .render = renderCamera },
    .{ .label = "Rest", .render = renderRest },
};

const cols: u32 = 4;
const thumb_w: u32 = 176;
const thumb_h: u32 = 380;
const gap_x: u32 = 30;
const gap_y: u32 = 46;
const margin: u32 = 40;

pub fn sheetWidth() u32 {
    return margin * 2 + cols * thumb_w + (cols - 1) * gap_x;
}
pub fn sheetHeight() u32 {
    const rows = (frames.len + cols - 1) / cols;
    return margin * 2 + @as(u32, @intCast(rows)) * (thumb_h + gap_y) + 40;
}

/// Area-downsamples `src` into the rectangle (dx,dy,dw,dh) of `dst`, averaging each destination pixel
/// over its source footprint so the thumbnail is smooth rather than aliased.
fn blitScaled(dst: *Framebuffer, dx: u32, dy: u32, dw: u32, dh: u32, src: Framebuffer) void {
    var oy: u32 = 0;
    while (oy < dh) : (oy += 1) {
        const sy0 = oy * src.height / dh;
        const sy1 = @max(sy0 + 1, (oy + 1) * src.height / dh);
        var ox: u32 = 0;
        while (ox < dw) : (ox += 1) {
            const sx0 = ox * src.width / dw;
            const sx1 = @max(sx0 + 1, (ox + 1) * src.width / dw);
            var r: u32 = 0;
            var gc: u32 = 0;
            var b: u32 = 0;
            var count: u32 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const p = src.get(sx, sy);
                    r += p.r;
                    gc += p.g;
                    b += p.b;
                    count += 1;
                }
            }
            if (count == 0) count = 1;
            dst.set(dx + ox, dy + oy, .{ .r = @intCast(r / count), .g = @intCast(gc / count), .b = @intCast(b / count), .a = 255 });
        }
    }
}

/// Renders the whole tour into `sheet`, which must be sized `sheetWidth()` x `sheetHeight()`.
pub fn render(allocator: std.mem.Allocator, sheet: *Framebuffer) !void {
    // Sheet background.
    paint.paint(sheet, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = sheet.width, .h = sheet.height },
        .top = paint.sample(theme.base),
        .bottom = paint.sample(theme.panel),
    } }});
    _ = text.draw(sheet, 40, 40, "The tour, boot to rest", 20, paint.sample(theme.text_primary));

    for (frames, 0..) |frame, index| {
        const col: u32 = @intCast(index % cols);
        const row: u32 = @intCast(index / cols);
        const x = margin + col * (thumb_w + gap_x);
        const y = 70 + margin + row * (thumb_h + gap_y);

        // Render the frame full-size, then downsample it into its thumbnail slot.
        var full = try Framebuffer.init(allocator, screen_w, screen_h, paint.sample(theme.base));
        defer full.deinit();
        frame.render(&full);
        blitScaled(sheet, x, y, thumb_w, thumb_h, full);

        text.drawCentred(sheet, @as(f32, @floatFromInt(x + thumb_w / 2)), @as(f32, @floatFromInt(y + thumb_h)) + 24.0, frame.label, 13, paint.sample(theme.text_secondary));
    }
}

const testing = std.testing;

test "the sheet dimensions hold every frame" {
    // Enough rows exist for all frames.
    const rows = (frames.len + cols - 1) / cols;
    try testing.expect(sheetHeight() >= margin * 2 + @as(u32, @intCast(rows)) * thumb_h);
}

test "the tour renders every frame into the sheet" {
    var sheet = try Framebuffer.init(testing.allocator, sheetWidth(), sheetHeight(), paint.sample(theme.base));
    defer sheet.deinit();
    try render(testing.allocator, &sheet);
    // The first thumbnail area holds rendered content (not the bare background).
    const p = sheet.get(margin + thumb_w / 2, 70 + margin + thumb_h / 2);
    try testing.expect(p.r != 0 or p.g != 0 or p.b != 0);
}

test "downsampling averages a solid source to that colour" {
    var src = try Framebuffer.init(testing.allocator, 8, 8, .{ .r = 100, .g = 150, .b = 200, .a = 255 });
    defer src.deinit();
    var dst = try Framebuffer.init(testing.allocator, 4, 4, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer dst.deinit();
    blitScaled(&dst, 0, 0, 4, 4, src);
    const p = dst.get(1, 1);
    try testing.expectEqual(@as(u8, 100), p.r);
    try testing.expectEqual(@as(u8, 150), p.g);
    try testing.expectEqual(@as(u8, 200), p.b);
}
