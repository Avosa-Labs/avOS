//! The physical device: a light phone screen set into a dark bezel on a dark desktop.
//!
//! Every app screen renders onto its own light framebuffer at the phone's logical size; this module
//! wraps that screen in the device the reference design draws around it — a dark radial desktop wash, a
//! brushed dark bezel with a large corner radius, and the light screen composited inside with its corners
//! clipped so the bezel shows through. It also paints the two pieces of chrome every screen shares: the
//! status bar at the top (clock and indicators) and the home indicator at the bottom. Keeping the device
//! frame here means an app screen only ever thinks in its own coordinates, and the window and the frame
//! writer both get the identical phone by calling one function.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

// The screen's logical size (the "Pro" proportion) and the window that holds the framed device.
pub const screen_w: u32 = theme.screen_pro_w;
pub const screen_h: u32 = theme.screen_pro_h;

pub const bezel: u32 = theme.bezel_thickness;
pub const margin: u32 = theme.desktop_margin;

pub const device_w: u32 = screen_w + bezel * 2;
pub const device_h: u32 = screen_h + bezel * 2;
pub const window_w: u32 = device_w + margin * 2;
pub const window_h: u32 = device_h + margin * 2;

/// Where the light screen sits inside the window.
pub const screen_x: i32 = @intCast(margin + bezel);
pub const screen_y: i32 = @intCast(margin + bezel);

/// A fresh light screen framebuffer for an app to draw onto. Caller owns it.
pub fn blankScreen(gpa: std.mem.Allocator) !Framebuffer {
    return Framebuffer.init(gpa, screen_w, screen_h, s(theme.screen_top));
}

/// Paints the light screen wash — the gradient every app screen rests on.
pub fn screenWash(screen: *Framebuffer) void {
    paint.paint(screen, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h },
        .top = s(theme.screen_top),
        .bottom = s(theme.screen_bottom),
    } }});
}

/// Paints the desktop and the device bezel into the window, leaving the screen area for a composite.
pub fn renderDevice(window: *Framebuffer) void {
    // The desktop the phone rests on: a dark wash, brighter at the top like the design's radial.
    paint.paint(window, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = window_w, .h = window_h },
        .top = s(theme.desktop_top),
        .bottom = s(theme.desktop_bottom),
    } }});
    // The device body: a brushed dark bezel with a large radius.
    paint.paint(window, &.{.{ .rounded_vgradient = .{
        .rect = .{ .x = @intCast(margin), .y = @intCast(margin), .w = device_w, .h = device_h },
        .radius = theme.device_radius,
        .top = s(theme.bezel_top),
        .bottom = s(theme.bezel_bottom),
    } }});
}

/// Composites a rendered light screen into the device, clipping its corners to the screen radius.
pub fn composite(window: *Framebuffer, screen: Framebuffer) void {
    paint.compositeRounded(window, screen, screen_x, screen_y, theme.screen_radius);
}

/// The status bar on a light screen: the clock left, signal/battery indicators right. Drawn in the
/// screen's own coordinates near the top, clear of the rounded corners.
pub fn statusBar(screen: *Framebuffer) void {
    _ = text.draw(screen, 26, 22, "9:41", 15, s(theme.screen_text));
    // Three signal-strength bars, rising.
    var bar: u8 = 0;
    while (bar < 3) : (bar += 1) {
        const h: u32 = 4 + @as(u32, bar) * 3;
        const bx: i32 = @intCast(screen_w - 58 + @as(u32, bar) * 6);
        paint.paint(screen, &.{.{ .rounded = .{
            .rect = .{ .x = bx, .y = @intCast(30 - h), .w = 4, .h = h },
            .radius = 1,
            .colour = s(theme.screen_text),
        } }});
    }
    // The battery: an outline with a fill and a nub.
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = .{ .x = @intCast(screen_w - 34), .y = 18, .w = 22, .h = 11 },
        .radius = 3,
        .colour = s(theme.screen_hairline),
    } }});
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = .{ .x = @intCast(screen_w - 32), .y = 20, .w = 16, .h = 7 },
        .radius = 2,
        .colour = s(theme.screen_text),
    } }});
    paint.paint(screen, &.{.{ .solid = .{
        .rect = .{ .x = @intCast(screen_w - 11), .y = 21, .w = 2, .h = 5 },
        .colour = s(theme.screen_text_muted),
    } }});
}

/// The home indicator: a rounded pill centred at the very bottom of the screen.
pub fn homeIndicator(screen: *Framebuffer) void {
    const pill_w: u32 = 134;
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = .{ .x = @intCast((screen_w - pill_w) / 2), .y = @intCast(screen_h - 15), .w = pill_w, .h = 5 },
        .radius = 3,
        .colour = s(theme.screen_text),
    } }});
}

const testing = std.testing;

test "the window holds the whole framed device with a margin" {
    try testing.expect(window_w == device_w + margin * 2);
    try testing.expect(window_h == device_h + margin * 2);
    try testing.expect(device_w == screen_w + bezel * 2);
}

test "the screen origin lands inside the bezel" {
    try testing.expect(screen_x == @as(i32, @intCast(margin + bezel)));
    try testing.expect(screen_y >= @as(i32, @intCast(margin)));
}

test "a composited screen shows the bezel at the extreme corner and the screen at the centre" {
    var window = try Framebuffer.init(testing.allocator, window_w, window_h, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer window.deinit();
    var screen = try blankScreen(testing.allocator);
    defer screen.deinit();
    renderDevice(&window);
    screenWash(&screen);
    composite(&window, screen);
    // Screen centre is the light wash.
    const centre = window.get(window_w / 2, window_h / 2);
    try testing.expect(centre.r > 0xd0 and centre.g > 0xd0 and centre.b > 0xd0);
    // The exact screen corner pixel is clipped away, so the bezel (dark) shows there.
    const corner = window.get(@intCast(screen_x), @intCast(screen_y));
    try testing.expect(corner.r < 0x80 and corner.g < 0x80 and corner.b < 0x80);
}
