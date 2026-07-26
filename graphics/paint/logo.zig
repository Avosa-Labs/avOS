//! The brand mark: the boot logo, drawn as vector so it renders at any size on any path.
//!
//! The mark is a disc with the brand's diagonal blue-to-cyan gradient and a white
//! lowercase "a" — a round bowl with its counter open to the gradient, closed on the
//! right by a straight stem. It is drawn from the same primitives as the rest of the
//! interface (a gradient disc, a stroked ring, a rounded bar), so it needs no image
//! asset and stays crisp from a boot splash to a favicon. Every colour comes from the
//! design tokens, so the mark restyles with the brand rather than carrying its own.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const design = @import("design");
const theme = design.theme;

const Framebuffer = fb.Framebuffer;

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Draws the real brand mark image centred at (cx, cy) with radius `r` (half the mark's
/// edge). The artwork is sampled bilinearly and alpha-blended, so its transparent corners
/// carry the circle's edge — the actual logo, scaled, not a redrawing of it.
pub fn draw(target: *Framebuffer, cx: f32, cy: f32, r: f32) void {
    const src = design.brand_mark.rgba;
    const n: f32 = @floatFromInt(design.brand_mark.size);
    const nu: u32 = design.brand_mark.size;
    const diameter = 2.0 * r;

    const x0: i32 = @intFromFloat(@floor(cx - r));
    const y0: i32 = @intFromFloat(@floor(cy - r));
    const x1: i32 = @intFromFloat(@ceil(cx + r));
    const y1: i32 = @intFromFloat(@ceil(cy + r));

    var ty = y0;
    while (ty < y1) : (ty += 1) {
        if (ty < 0 or ty >= @as(i32, @intCast(target.height))) continue;
        var tx = x0;
        while (tx < x1) : (tx += 1) {
            if (tx < 0 or tx >= @as(i32, @intCast(target.width))) continue;
            // Source coordinate in the mark, in pixels.
            const u = (@as(f32, @floatFromInt(tx)) + 0.5 - (cx - r)) / diameter * n - 0.5;
            const v = (@as(f32, @floatFromInt(ty)) + 0.5 - (cy - r)) / diameter * n - 0.5;
            const sample = bilinear(src, nu, u, v);
            if (sample[3] == 0) continue;
            target.blend(@intCast(tx), @intCast(ty), .{ .r = sample[0], .g = sample[1], .b = sample[2], .a = 255 }, sample[3]);
        }
    }
}

/// Bilinear sample of an RGBA image at floating (u, v) in pixel space, clamped to edges.
fn bilinear(src: []const u8, n: u32, u: f32, v: f32) [4]u8 {
    const maxc: f32 = @floatFromInt(n - 1);
    const fu = std.math.clamp(u, 0.0, maxc);
    const fv = std.math.clamp(v, 0.0, maxc);
    const cu0: u32 = @intFromFloat(@floor(fu));
    const cv0: u32 = @intFromFloat(@floor(fv));
    const cu1 = @min(cu0 + 1, n - 1);
    const cv1 = @min(cv0 + 1, n - 1);
    const du = fu - @floor(fu);
    const dv = fv - @floor(fv);
    var out: [4]u8 = undefined;
    for (0..4) |ch| {
        const p00: f32 = @floatFromInt(src[(cv0 * n + cu0) * 4 + ch]);
        const p10: f32 = @floatFromInt(src[(cv0 * n + cu1) * 4 + ch]);
        const p01: f32 = @floatFromInt(src[(cv1 * n + cu0) * 4 + ch]);
        const p11: f32 = @floatFromInt(src[(cv1 * n + cu1) * 4 + ch]);
        const top = p00 + (p10 - p00) * du;
        const bot = p01 + (p11 - p01) * du;
        out[ch] = @intFromFloat(@round(top + (bot - top) * dv));
    }
    return out;
}

/// Draws the mark as vector primitives — the fallback when the artwork is unavailable,
/// and the source of the `logo` gradient token. Centred at (cx, cy) with disc radius `r`.
pub fn drawVector(target: *Framebuffer, cx: f32, cy: f32, r: f32) void {
    // The disc: the brand's diagonal gradient, indigo at the upper-left to cyan at the
    // lower-right.
    vector.fillDiscGradient(target, cx, cy, r, s(theme.logo.top), s(theme.logo.bottom));

    const mark = s(theme.text_primary); // the near-white the letter is cut in

    // The bowl: a thick white ring set low and left, its counter left open so the
    // gradient shows through — the hole of the "a".
    const bowl_cx = cx - 0.15 * r;
    const bowl_cy = cy + 0.16 * r;
    const bowl_r = 0.39 * r;
    const bowl_weight = 0.18 * r;
    vector.strokeCircle(target, bowl_cx, bowl_cy, bowl_r, bowl_weight, mark);

    // The stem: a straight white bar on the right that closes the bowl and drops below
    // it, the upright of the "a". It overlaps the bowl's right edge so the two read as
    // one letter.
    const stem_w = 0.18 * r;
    const stem_x = cx + 0.22 * r;
    const stem_top = cy - 0.34 * r;
    const stem_bottom = cy + 0.55 * r;
    paint.paint(target, &.{.{ .rounded = .{
        .rect = .{
            .x = @intFromFloat(@round(stem_x - stem_w * 0.5)),
            .y = @intFromFloat(@round(stem_top)),
            .w = @intFromFloat(@round(stem_w)),
            .h = @intFromFloat(@round(stem_bottom - stem_top)),
        },
        .radius = @intFromFloat(@round(stem_w * 0.5)),
        .colour = mark,
    } }});
}

const testing = std.testing;

test "the mark paints the gradient disc and a lighter letter over it" {
    var target = try Framebuffer.init(testing.allocator, 200, 200, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    draw(&target, 100, 100, 80);

    // The disc's upper-left is the indigo end; the lower-right is the cyan end. Cyan has
    // a higher blue-green content than indigo, so the lower-right reads bluer/greener.
    const upper_left = target.get(70, 70);
    const lower_right = target.get(130, 130);
    try testing.expect(lower_right.g > upper_left.g);

    // The letter is near-white, brighter than either end of the gradient. Some pixel in
    // the mark's region is close to white.
    var found_light = false;
    var y: u32 = 60;
    while (y < 140 and !found_light) : (y += 1) {
        var x: u32 = 60;
        while (x < 140) : (x += 1) {
            const p = target.get(x, y);
            if (p.r > 0xe0 and p.g > 0xe0 and p.b > 0xe0) {
                found_light = true;
                break;
            }
        }
    }
    try testing.expect(found_light);
}
