//! The Music now-playing screen, rendered bespoke and driven by real data.
//!
//! Music's own layout: the artwork as a large raised tile floating on the soft shadow, the track and
//! artist beneath it, a progress track with elapsed and total times, and a transport row — a chevron
//! back, a filled play/pause, a chevron forward. Every string and the progress fraction are fields of
//! the `MusicView` the shell fills from the real domain; the artwork tile is a gradient placeholder
//! until real cover art is decoded. Graphics stays app-agnostic: plain data in, pixels out.
//!
//! Rendered portrait at a phone's proportions. Bounded work: a fixed set of fills and the text runs,
//! O(1) in the content.

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

/// Everything the now-playing screen draws, filled by the shell from the real domain.
pub const MusicView = struct {
    title: []const u8,
    artist: []const u8,
    elapsed: []const u8, // "1:24"
    duration: []const u8, // "3:57"
    progress: f32, // 0..1, the played fraction
    playing: bool,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the now-playing screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: MusicView) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));

    // The artwork: a large raised tile floating on the shadow. A gradient placeholder until real cover
    // art is decoded into it.
    const art: Rect = .{ .x = 45, .y = 110, .w = 300, .h = 300 };
    paint.paint(target, &.{
        .{ .shadow = .{
            .rect = .{ .x = art.x, .y = art.y + theme.shadow_offset_y, .w = art.w, .h = art.h },
            .radius = theme.radius_xl,
            .blur = theme.shadow_blur,
            .colour = s(theme.shadow_tint),
            .alpha = theme.shadow_tint.alpha,
        } },
        .{ .rounded_vgradient = .{
            .rect = art,
            .radius = theme.radius_xl,
            .top = s(theme.agent_soft),
            .bottom = s(theme.agent),
        } },
    });

    const cx: f32 = @floatFromInt(width / 2);
    text.drawCentred(target, cx, 470, view.title, 26, s(theme.screen_text));
    text.drawCentred(target, cx, 502, view.artist, 16, s(theme.screen_text_muted));

    // The progress track: a full pill, with the played fraction filled in the accent.
    const track: Rect = .{ .x = 45, .y = 552, .w = 300, .h = 6 };
    const played: u32 = @intFromFloat(@min(@max(view.progress, 0.0), 1.0) * @as(f32, @floatFromInt(track.w)));
    paint.paint(target, &.{
        .{ .rounded = .{ .rect = track, .radius = 3, .colour = s(theme.surface_raised) } },
        .{ .rounded = .{ .rect = .{ .x = track.x, .y = track.y, .w = played, .h = track.h }, .radius = 3, .colour = s(theme.agent) } },
    });
    _ = text.draw(target, @floatFromInt(track.x), 582, view.elapsed, 12, s(theme.screen_text_muted));
    const dur_w = text.measure(view.duration, 12);
    _ = text.draw(target, @as(f32, @floatFromInt(track.x + @as(i32, @intCast(track.w)))) - dur_w, 582, view.duration, 12, s(theme.screen_text_muted));

    // Transport: a chevron back, the play/pause, a chevron forward.
    const row_y: f32 = 660;
    chevron(target, 110, row_y, false, s(theme.screen_text));
    chevron(target, 280, row_y, true, s(theme.screen_text));
    // Play/pause: a filled accent disc; a pause is two bars, a play is a triangle of bars standing in.
    vector.fillDisc(target, cx, row_y, 34, s(theme.agent));
    if (view.playing) {
        // Two pause bars.
        paint.paint(target, &.{
            .{ .rounded = .{ .rect = .{ .x = @as(i32, @intFromFloat(cx)) - 10, .y = @as(i32, @intFromFloat(row_y)) - 12, .w = 6, .h = 24 }, .radius = 2, .colour = s(theme.base) } },
            .{ .rounded = .{ .rect = .{ .x = @as(i32, @intFromFloat(cx)) + 4, .y = @as(i32, @intFromFloat(row_y)) - 12, .w = 6, .h = 24 }, .radius = 2, .colour = s(theme.base) } },
        });
    } else {
        // A play glyph: a small right-pointing triangle drawn as a filled polyline fan approximation.
        vector.strokePolyline(target, &.{
            .{ .x = cx - 8, .y = row_y - 12 }, .{ .x = cx + 12, .y = row_y }, .{ .x = cx - 8, .y = row_y + 12 }, .{ .x = cx - 8, .y = row_y - 12 },
        }, 3, s(theme.base), true);
    }
}

/// A chevron pointing left (forward=false) or right (forward=true), centred at (cx, cy).
fn chevron(target: *Framebuffer, cx: f32, cy: f32, forward: bool, colour: fb.Rgba) void {
    const w: f32 = 8;
    const h: f32 = 11;
    const tip = if (forward) cx + w else cx - w;
    const back = if (forward) cx - w else cx + w;
    vector.strokePolyline(target, &.{
        .{ .x = back, .y = cy - h }, .{ .x = tip, .y = cy }, .{ .x = back, .y = cy + h },
    }, 3, colour, false);
}

// --- Tests ---

const testing = std.testing;

fn sampleView() MusicView {
    return .{ .title = "Meridian", .artist = "Ana Roso", .elapsed = "1:24", .duration = "3:57", .progress = 0.36, .playing = true };
}

test "the now-playing screen paints artwork, track text, and transport" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    try testing.expect(target.digest() != before);
    try testing.expect(target.get(2, 2).a == 255); // gradient filled
    // The artwork tile interior has ink over the background.
    try testing.expect(target.get(195, 260).r != target.get(2, 2).r);
}

test "a zero and a full progress both stay within the track and do not crash" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    var v = sampleView();
    v.progress = 0.0;
    render(&target, v);
    v.progress = 1.0;
    v.playing = false;
    render(&target, v);
    try testing.expect(target.get(2, 2).a == 255);
}
