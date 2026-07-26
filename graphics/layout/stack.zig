//! Vertical stacking over the flex engine: a list surface is a flex column.
//!
//! The designed app surfaces are columns — a header, then section labels and cards flowing
//! down the screen with a consistent gap. Placing them by accumulating a `y` cursor is
//! exactly the hand arithmetic the layout engine exists to retire. This expresses the column
//! as `flex` items (each block a fixed main-axis height) and returns the top of each block,
//! so a surface declares its blocks and the engine decides where they land.
//!
//! It is a thin convenience over `flex.solve` for the common one-column case; anything richer
//! (a row within a card, nested containers) calls `flex.solve` directly.

const std = @import("std");
const flex = @import("flex.zig");

/// The most blocks a single surface stacks — every designed screen is well under this.
pub const max_blocks: usize = 64;

/// Fills `out_tops` with the top coordinate of each block, stacking `heights` down from
/// `top` with `gap` between blocks. `out_tops.len` must be at least `heights.len`, and
/// `heights.len` at most `max_blocks`.
pub fn columnTops(top: f32, heights: []const f32, gap: f32, out_tops: []f32) void {
    std.debug.assert(heights.len <= max_blocks);
    std.debug.assert(out_tops.len >= heights.len);
    if (heights.len == 0) return;

    var items: [max_blocks]flex.Item = undefined;
    var rects: [max_blocks]flex.Rect = undefined;
    var total: f32 = gap * @as(f32, @floatFromInt(heights.len - 1));
    for (heights, 0..) |h, i| {
        items[i] = .{ .main = .{ .fixed = h } };
        total += h;
    }

    // A column exactly as tall as its content: justify-start places blocks flush from the
    // top with the gap between them, so each rect's y is its offset from the stack top.
    flex.solve(
        .{ .axis = .column, .gap = gap },
        items[0..heights.len],
        .{ .w = 0, .h = total },
        rects[0..heights.len],
    );
    for (rects[0..heights.len], 0..) |r, i| out_tops[i] = top + r.y;
}

const testing = std.testing;

fn approx(a: f32, b: f32) !void {
    try testing.expect(@abs(a - b) < 1e-3);
}

test "blocks stack from the top with the gap between them" {
    const heights = [_]f32{ 24, 68, 68, 8 };
    var tops: [4]f32 = undefined;
    columnTops(122, &heights, 0, &tops);
    try approx(tops[0], 122); // first block at the top
    try approx(tops[1], 146); // 122 + 24
    try approx(tops[2], 214); // + 68
    try approx(tops[3], 282); // + 68
}

test "a non-zero gap separates every block" {
    const heights = [_]f32{ 60, 60, 60 };
    var tops: [3]f32 = undefined;
    columnTops(120, &heights, 8, &tops);
    try approx(tops[0], 120);
    try approx(tops[1], 188); // 120 + 60 + 8
    try approx(tops[2], 256); // + 60 + 8
}

test "an empty stack places nothing" {
    var tops: [1]f32 = undefined;
    columnTops(100, &.{}, 8, &tops); // must not touch out_tops or trip an assert
}
