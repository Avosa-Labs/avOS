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
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Draws the mark centred at (cx, cy) with disc radius `r`. The "a" is proportioned to
/// the disc, so scaling `r` scales the whole mark.
pub fn draw(target: *Framebuffer, cx: f32, cy: f32, r: f32) void {
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
