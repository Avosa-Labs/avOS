//! The app icon glyphs: the white line symbols drawn on each tile.
//!
//! Every app tile is the same squircle in a per-app gradient, and what tells them apart is the white
//! symbol on top — a handset, a speech bubble, a waveform. Each glyph is built from the vector
//! primitives (strokes, discs, rings) at a consistent stroke weight and inset, so the whole set reads as
//! one family rather than a collection of unrelated marks. A glyph is defined in a normalized
//! coordinate space over the tile — points in [0,1] — and mapped into the tile's actual rectangle when
//! drawn, so one definition renders crisply at any tile size. Drawing the tile and its glyph together is
//! how a single call produces a finished, on-brand app icon.
//!
//! This module composes the render primitives; it makes no policy decisions.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const svg_icon = @import("svg_icon.zig");
const design = @import("design");
const theme = design.theme;
const glyphs = design.icons.glyphs;

const Framebuffer = fb.Framebuffer;
const Rgba = fb.Rgba;
const Point = vector.Point;

const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// The apps whose icons this module can draw. The first twelve are the platform's default
/// applications; the rest are additional tiles kept for tooling and are not surfaced as default apps.
pub const App = enum {
    // The twelve default applications.
    agents,
    settings,
    messages,
    phone,
    calendar,
    files,
    contacts,
    camera,
    weather,
    browser,
    calculator,
    store,
    // Additional tiles (not default apps).
    health,
    mail,
    notes,
    maps,
};

/// The gradient a given app's tile uses.
pub fn gradientFor(app: App) theme.Gradient {
    return switch (app) {
        .phone => theme.icon_phone,
        .messages => theme.icon_messages,
        .calendar => theme.icon_calendar,
        .camera => theme.icon_camera,
        .agents => theme.icon_agents,
        .files => theme.icon_files,
        .settings => theme.icon_settings,
        .weather => theme.icon_weather,
        .contacts => theme.icon_contacts,
        .browser => theme.icon_browser,
        .calculator => theme.icon_calculator,
        .store => theme.icon_store,
        .health => theme.icon_health,
        .mail => theme.icon_mail,
        .notes => theme.icon_notes,
        .maps => theme.icon_maps,
    };
}

/// Maps a normalized glyph point (0..1 over the tile) to a device point.
fn map(rect: paint.Rect, nx: f32, ny: f32) Point {
    return .{
        .x = @as(f32, @floatFromInt(rect.x)) + nx * @as(f32, @floatFromInt(rect.w)),
        .y = @as(f32, @floatFromInt(rect.y)) + ny * @as(f32, @floatFromInt(rect.h)),
    };
}

fn stroke(target: *Framebuffer, rect: paint.Rect, pts: []const [2]f32, w: f32, closed: bool) void {
    var buffer: [24]Point = undefined;
    const count = @min(pts.len, buffer.len);
    for (pts[0..count], 0..) |p, index| buffer[index] = map(rect, p[0], p[1]);
    vector.strokePolyline(target, buffer[0..count], w, white, closed);
}

/// Draws a complete app icon — the squircle tile in its gradient, then its white glyph — into `rect`.
pub fn draw(target: *Framebuffer, rect: paint.Rect, app: App) void {
    const radius = @as(u32, @intCast(rect.w)) * theme.icon_radius_ratio_num / theme.icon_radius_ratio_den;
    const gradient = gradientFor(app);
    paint.paint(target, &.{.{ .rounded_vgradient = .{
        .rect = rect,
        .radius = radius,
        .top = paint.sample(gradient.top),
        .bottom = paint.sample(gradient.bottom),
    } }});

    // Prefer the delivered glyph: the designed 24-grid SVG, rendered white and centred on the tile.
    // Apps without a delivered symbol keep their hand-built glyph so the whole set still reads.
    if (deliveredGlyph(app)) |svg| {
        svg_icon.drawInRect(target, svg, rect.x, rect.y, rect.w, rect.h, 0.58, white);
        return;
    }

    const side = @as(f32, @floatFromInt(rect.w));
    const w = side * 0.075; // stroke weight, proportional to the tile
    switch (app) {
        .phone => drawPhone(target, rect, w),
        .messages => drawMessages(target, rect, w),
        .calendar => drawCalendar(target, rect, w),
        .camera => drawCamera(target, rect, w),
        .health => drawHealth(target, rect, w),
        .agents => drawAgents(target, rect, w),
        .files => drawFiles(target, rect, w),
        .settings => drawSettings(target, rect, w),
        .contacts => drawContacts(target, rect, w),
        .browser => drawBrowser(target, rect, w),
        .calculator => drawCalculator(target, rect, w),
        .store => drawStore(target, rect, w),
        .mail => drawMail(target, rect, w),
        .weather => drawWeather(target, rect, w),
        .notes => drawNotes(target, rect, w),
        .maps => drawMaps(target, rect, w),
    }
}

/// The delivered glyph asset for an app tile, or null when the app has no designed symbol yet and
/// should keep its hand-built glyph.
fn deliveredGlyph(app: App) ?[]const u8 {
    return switch (app) {
        .phone => glyphs.call,
        .messages => glyphs.message,
        .calendar => glyphs.calendar,
        .camera => glyphs.camera,
        .agents => glyphs.agent,
        .files => glyphs.folder,
        .settings => glyphs.settings,
        .browser => glyphs.globe,
        .maps => glyphs.location,
        .health => glyphs.running,
        .notes => glyphs.file,
        .contacts, .calculator, .store, .mail, .weather => null,
    };
}

fn drawPhone(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A handset: a curved diagonal bar whose round stroke caps form the ear (top-left) and mouth
    // (bottom-right) cups. The slight curve reads as a receiver rather than a straight bar.
    stroke(target, rect, &.{
        .{ 0.36, 0.32 }, .{ 0.33, 0.38 }, .{ 0.40, 0.50 }, .{ 0.52, 0.62 }, .{ 0.64, 0.69 }, .{ 0.70, 0.66 },
    }, w * 1.25, false);
}

fn drawMessages(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A rounded speech bubble outline with a tail.
    stroke(target, rect, &.{
        .{ 0.30, 0.32 }, .{ 0.70, 0.32 }, .{ 0.72, 0.36 }, .{ 0.72, 0.58 },
        .{ 0.70, 0.62 }, .{ 0.44, 0.62 }, .{ 0.36, 0.70 }, .{ 0.38, 0.62 },
        .{ 0.30, 0.62 }, .{ 0.28, 0.58 }, .{ 0.28, 0.36 },
    }, w, true);
}

fn drawCalendar(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A rounded square with a header bar and two eyes — the friendly calendar face.
    stroke(target, rect, &.{ .{ 0.30, 0.34 }, .{ 0.70, 0.34 }, .{ 0.70, 0.68 }, .{ 0.30, 0.68 } }, w, true);
    stroke(target, rect, &.{ .{ 0.30, 0.44 }, .{ 0.70, 0.44 } }, w, false); // header divider
    vector.fillDisc(target, map(rect, 0.42, 0.56).x, map(rect, 0.42, 0.56).y, w * 0.9, white);
    vector.fillDisc(target, map(rect, 0.58, 0.56).x, map(rect, 0.58, 0.56).y, w * 0.9, white);
}

fn drawCamera(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A body with a small top bump and a lens ring.
    stroke(target, rect, &.{ .{ 0.42, 0.34 }, .{ 0.58, 0.34 }, .{ 0.60, 0.38 }, .{ 0.40, 0.38 } }, w, true); // bump
    stroke(target, rect, &.{ .{ 0.28, 0.40 }, .{ 0.72, 0.40 }, .{ 0.72, 0.66 }, .{ 0.28, 0.66 } }, w, true); // body
    vector.strokeCircle(target, map(rect, 0.50, 0.53).x, map(rect, 0.50, 0.53).y, @as(f32, @floatFromInt(rect.w)) * 0.10, w, white);
}

fn drawHealth(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A pulse waveform across the middle.
    stroke(target, rect, &.{
        .{ 0.26, 0.50 }, .{ 0.40, 0.50 }, .{ 0.46, 0.36 }, .{ 0.54, 0.64 }, .{ 0.60, 0.50 }, .{ 0.74, 0.50 },
    }, w * 1.2, false);
}

fn drawAgents(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // Two interlinked rings — agents working together, the "loop" mark.
    const r = @as(f32, @floatFromInt(rect.w)) * 0.11;
    vector.strokeCircle(target, map(rect, 0.42, 0.50).x, map(rect, 0.42, 0.50).y, r, w, white);
    vector.strokeCircle(target, map(rect, 0.58, 0.50).x, map(rect, 0.58, 0.50).y, r, w, white);
}

fn drawFiles(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A document with a folded top-right corner.
    stroke(target, rect, &.{
        .{ 0.34, 0.30 }, .{ 0.58, 0.30 }, .{ 0.66, 0.38 }, .{ 0.66, 0.70 }, .{ 0.34, 0.70 },
    }, w, true);
    stroke(target, rect, &.{ .{ 0.58, 0.30 }, .{ 0.58, 0.38 }, .{ 0.66, 0.38 } }, w, false); // fold
}

fn drawMail(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // An envelope: a rounded rectangle body with a V flap.
    stroke(target, rect, &.{ .{ 0.26, 0.36 }, .{ 0.74, 0.36 }, .{ 0.74, 0.64 }, .{ 0.26, 0.64 } }, w, true);
    stroke(target, rect, &.{ .{ 0.26, 0.38 }, .{ 0.50, 0.54 }, .{ 0.74, 0.38 } }, w, false);
}

fn drawWeather(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A sun: a small disc with rays around it.
    const cx = map(rect, 0.50, 0.50).x;
    const cy = map(rect, 0.50, 0.50).y;
    const r = @as(f32, @floatFromInt(rect.w)) * 0.11;
    vector.fillDisc(target, cx, cy, r, white);
    const rays = [_][2]f32{ .{ 0.50, 0.24 }, .{ 0.50, 0.76 }, .{ 0.24, 0.50 }, .{ 0.76, 0.50 }, .{ 0.32, 0.32 }, .{ 0.68, 0.68 }, .{ 0.32, 0.68 }, .{ 0.68, 0.32 } };
    for (rays) |ray| {
        const inner = mixToCentre(ray, 0.30);
        stroke(target, rect, &.{ inner, ray }, w * 0.8, false);
    }
}

fn mixToCentre(p: [2]f32, t: f32) [2]f32 {
    return .{ p[0] + (0.50 - p[0]) * t, p[1] + (0.50 - p[1]) * t };
}

fn drawNotes(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A page with three text lines.
    stroke(target, rect, &.{ .{ 0.30, 0.30 }, .{ 0.70, 0.30 }, .{ 0.70, 0.70 }, .{ 0.30, 0.70 } }, w, true);
    stroke(target, rect, &.{ .{ 0.38, 0.42 }, .{ 0.62, 0.42 } }, w * 0.7, false);
    stroke(target, rect, &.{ .{ 0.38, 0.50 }, .{ 0.62, 0.50 } }, w * 0.7, false);
    stroke(target, rect, &.{ .{ 0.38, 0.58 }, .{ 0.54, 0.58 } }, w * 0.7, false);
}

fn drawMaps(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A location pin: a teardrop with a hollow centre.
    stroke(target, rect, &.{
        .{ 0.50, 0.72 }, .{ 0.34, 0.50 }, .{ 0.36, 0.38 }, .{ 0.50, 0.30 }, .{ 0.64, 0.38 }, .{ 0.66, 0.50 }, .{ 0.50, 0.72 },
    }, w, true);
    vector.fillDisc(target, map(rect, 0.50, 0.44).x, map(rect, 0.50, 0.44).y, w * 0.9, white);
}

fn drawSettings(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // Two horizontal slider tracks at a thinner weight, each with a round knob at a different position,
    // so the pair reads clearly as sliders rather than merging into a blob.
    const track = w * 0.7;
    stroke(target, rect, &.{ .{ 0.26, 0.42 }, .{ 0.74, 0.42 } }, track, false);
    stroke(target, rect, &.{ .{ 0.26, 0.58 }, .{ 0.74, 0.58 } }, track, false);
    // Knobs: a filled disc ringed by the tile gradient is faked by drawing the disc slightly larger
    // than the track; the different x positions are the slider values.
    vector.fillDisc(target, map(rect, 0.40, 0.42).x, map(rect, 0.40, 0.42).y, w * 1.25, white);
    vector.fillDisc(target, map(rect, 0.62, 0.58).x, map(rect, 0.62, 0.58).y, w * 1.25, white);
}

fn drawContacts(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A person: a head and a shoulders arc.
    vector.strokeCircle(target, map(rect, 0.50, 0.40).x, map(rect, 0.50, 0.40).y, @as(f32, @floatFromInt(rect.w)) * 0.11, w, white);
    stroke(target, rect, &.{ .{ 0.30, 0.72 }, .{ 0.32, 0.62 }, .{ 0.42, 0.56 }, .{ 0.58, 0.56 }, .{ 0.68, 0.62 }, .{ 0.70, 0.72 } }, w, false);
}

fn drawBrowser(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A globe: a ring, an equator, and a meridian — the fallback when the delivered glyph is absent.
    const r = @as(f32, @floatFromInt(rect.w)) * 0.20;
    vector.strokeCircle(target, map(rect, 0.50, 0.50).x, map(rect, 0.50, 0.50).y, r, w, white);
    stroke(target, rect, &.{ .{ 0.30, 0.50 }, .{ 0.70, 0.50 } }, w * 0.85, false);
    stroke(target, rect, &.{ .{ 0.50, 0.30 }, .{ 0.42, 0.50 }, .{ 0.50, 0.70 }, .{ 0.58, 0.50 }, .{ 0.50, 0.30 } }, w * 0.85, true);
}

fn drawCalculator(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A calculator: a rounded body, a display bar, and a grid of keys.
    stroke(target, rect, &.{ .{ 0.32, 0.28 }, .{ 0.68, 0.28 }, .{ 0.68, 0.72 }, .{ 0.32, 0.72 } }, w, true);
    stroke(target, rect, &.{ .{ 0.38, 0.37 }, .{ 0.62, 0.37 } }, w * 0.8, false); // display
    const keys = [_][2]f32{ .{ 0.40, 0.50 }, .{ 0.50, 0.50 }, .{ 0.60, 0.50 }, .{ 0.40, 0.61 }, .{ 0.50, 0.61 }, .{ 0.60, 0.61 } };
    for (keys) |k| vector.fillDisc(target, map(rect, k[0], k[1]).x, map(rect, k[0], k[1]).y, w * 0.7, white);
}

fn drawStore(target: *Framebuffer, rect: paint.Rect, w: f32) void {
    // A shopping bag: a body that tapers in at the top, with a handle arc.
    stroke(target, rect, &.{ .{ 0.34, 0.40 }, .{ 0.66, 0.40 }, .{ 0.70, 0.72 }, .{ 0.30, 0.72 } }, w, true);
    stroke(target, rect, &.{ .{ 0.42, 0.44 }, .{ 0.42, 0.36 }, .{ 0.46, 0.30 }, .{ 0.54, 0.30 }, .{ 0.58, 0.36 }, .{ 0.58, 0.44 } }, w, false);
}

const testing = std.testing;

test "every app draws a tile with a white glyph over its gradient" {
    for (std.enums.values(App)) |app| {
        var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        defer target.deinit();
        draw(&target, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, app);
        // The tile is filled: the centre is not the cleared background.
        const centre = target.get(32, 32);
        try testing.expect(centre.r != 0 or centre.g != 0 or centre.b != 0);
        // Some pixel is near-white, i.e. the glyph was drawn.
        var found_white = false;
        var y: u32 = 0;
        while (y < 64 and !found_white) : (y += 1) {
            var x: u32 = 0;
            while (x < 64) : (x += 1) {
                const p = target.get(x, y);
                if (p.r > 230 and p.g > 230 and p.b > 230) {
                    found_white = true;
                    break;
                }
            }
        }
        try testing.expect(found_white);
    }
}

test "the corners of a tile are clipped by the squircle" {
    var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    draw(&target, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, .phone);
    try testing.expect(target.get(0, 0).r < 128); // corner clipped away
}

test "each app maps to its themed gradient" {
    try testing.expectEqual(theme.icon_phone.top.red, gradientFor(.phone).top.red);
    try testing.expectEqual(theme.icon_settings.bottom.blue, gradientFor(.settings).bottom.blue);
}
