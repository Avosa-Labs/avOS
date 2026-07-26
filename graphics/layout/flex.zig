//! A flexbox-like constraint layout, so the reference design translates mechanically.
//!
//! The design is authored in CSS flexbox — rows and columns with a gap, padding, a
//! main-axis distribution (justify-content), and a cross-axis alignment (align-items).
//! Rebuilding a screen by eye from that is where drift creeps in; a layout engine that
//! speaks the same model lets a screen be transcribed instead. This solves one container:
//! given its axis, gap, padding, justify, and align, and its items' main-axis sizing
//! (a fixed length or a flex weight) and optional cross-axis size, it computes each item's
//! rectangle. Nesting is the caller composing solves — a container's item rectangle
//! becomes the available box for its own children.
//!
//! It is decision logic, pure arithmetic over constraints — no C library, no drawing. The
//! renderer paints the rectangles this returns.

const std = @import("std");

pub const Axis = enum { row, column };

/// Main-axis distribution — CSS justify-content.
pub const Justify = enum { start, center, end, space_between, space_around, space_evenly };

/// Cross-axis alignment — CSS align-items.
pub const Align = enum { start, center, end, stretch };

pub const Size = struct { w: f32, h: f32 };
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// An item's main-axis sizing: a fixed length, or a flex weight that shares the leftover
/// space in proportion to the other flex items.
pub const Sizing = union(enum) {
    fixed: f32,
    flex: f32,
};

pub const Item = struct {
    main: Sizing,
    /// The item's cross-axis size. Null means it takes the container's alignment: stretched
    /// to the cross extent, or (for start/center/end) its own zero-based placement.
    cross: ?f32 = null,
};

pub const Container = struct {
    axis: Axis,
    justify: Justify = .start,
    cross_align: Align = .stretch,
    gap: f32 = 0,
    /// Uniform inner padding on all sides.
    padding: f32 = 0,
};

/// Lays a container's items into `out` (one rect per item, same order). The available box
/// is the container's outer size; padding insets the content, gap separates items.
pub fn solve(container: Container, items: []const Item, available: Size, out: []Rect) void {
    std.debug.assert(out.len >= items.len);
    if (items.len == 0) return;

    const n: f32 = @floatFromInt(items.len);
    const along_row = container.axis == .row;
    const main_extent = (if (along_row) available.w else available.h) - 2 * container.padding;
    const cross_extent = (if (along_row) available.h else available.w) - 2 * container.padding;
    const total_gap = container.gap * (n - 1);

    // Resolve main-axis sizes: fixed as given, flex sharing the leftover.
    var pinned_total: f32 = 0;
    var flex_sum: f32 = 0;
    for (items) |item| switch (item.main) {
        .fixed => |v| pinned_total += v,
        .flex => |w| flex_sum += w,
    };
    const leftover = @max(0.0, main_extent - total_gap - pinned_total);

    var content_main: f32 = 0;
    var buffer_main: [64]f32 = undefined; // resolved main size per item (bounded)
    const sizes = buffer_main[0..items.len];
    for (items, 0..) |item, i| {
        sizes[i] = switch (item.main) {
            .fixed => |v| v,
            .flex => |w| if (flex_sum > 0) leftover * (w / flex_sum) else 0,
        };
        content_main += sizes[i];
    }
    content_main += total_gap;

    // Position along the main axis per justify. `cursor` is the first item's start; `step`
    // is the extra space inserted between items beyond the gap.
    const free = @max(0.0, main_extent - content_main);
    var cursor: f32 = container.padding;
    var extra: f32 = 0;
    switch (container.justify) {
        .start => {},
        .center => cursor += free / 2,
        .end => cursor += free,
        .space_between => extra = if (items.len > 1) free / (n - 1) else 0,
        .space_around => {
            extra = free / n;
            cursor += extra / 2;
        },
        .space_evenly => {
            extra = free / (n + 1);
            cursor += extra;
        },
    }

    for (items, 0..) |item, i| {
        const main_pos = cursor;
        const main_size = sizes[i];

        // Cross-axis: stretch fills the extent; otherwise the item's own size, aligned.
        const cross_size = item.cross orelse (if (container.cross_align == .stretch) cross_extent else 0);
        const cross_pos = container.padding + switch (container.cross_align) {
            .start, .stretch => 0,
            .center => (cross_extent - cross_size) / 2,
            .end => cross_extent - cross_size,
        };

        out[i] = if (along_row)
            .{ .x = main_pos, .y = cross_pos, .w = main_size, .h = cross_size }
        else
            .{ .x = cross_pos, .y = main_pos, .w = cross_size, .h = main_size };

        cursor += main_size + container.gap + extra;
    }
}

const testing = std.testing;

fn approx(a: f32, b: f32) !void {
    try testing.expect(@abs(a - b) < 1e-3);
}

test "three flex items split a row evenly, stretched to the cross axis" {
    const items = [_]Item{ .{ .main = .{ .flex = 1 } }, .{ .main = .{ .flex = 1 } }, .{ .main = .{ .flex = 1 } } };
    var out: [3]Rect = undefined;
    solve(.{ .axis = .row, .gap = 0 }, &items, .{ .w = 300, .h = 100 }, &out);
    try approx(out[0].x, 0);
    try approx(out[0].w, 100);
    try approx(out[1].x, 100);
    try approx(out[2].x, 200);
    try approx(out[0].h, 100); // stretched
}

test "fixed and flex mix: fixed keeps its size, flex takes the rest" {
    const items = [_]Item{ .{ .main = .{ .fixed = 80 } }, .{ .main = .{ .flex = 1 } } };
    var out: [2]Rect = undefined;
    solve(.{ .axis = .row, .gap = 0 }, &items, .{ .w = 200, .h = 50 }, &out);
    try approx(out[0].w, 80);
    try approx(out[1].w, 120);
    try approx(out[1].x, 80);
}

test "gap and padding inset the content" {
    const items = [_]Item{ .{ .main = .{ .fixed = 40 } }, .{ .main = .{ .fixed = 40 } } };
    var out: [2]Rect = undefined;
    solve(.{ .axis = .row, .gap = 20, .padding = 10 }, &items, .{ .w = 200, .h = 60 }, &out);
    try approx(out[0].x, 10); // padding
    try approx(out[1].x, 70); // 10 + 40 + 20 gap
    try approx(out[0].y, 10); // padding on the cross axis too
    try approx(out[0].h, 40); // 60 - 2*10 padding
}

test "space-between pins the ends and spreads the gaps" {
    const items = [_]Item{ .{ .main = .{ .fixed = 40 } }, .{ .main = .{ .fixed = 40 } }, .{ .main = .{ .fixed = 40 } } };
    var out: [3]Rect = undefined;
    solve(.{ .axis = .row, .justify = .space_between }, &items, .{ .w = 300, .h = 50 }, &out);
    try approx(out[0].x, 0); // first flush left
    try approx(out[2].x, 260); // last flush right (300 - 40)
    try approx(out[1].x, 130); // centred between
}

test "centre alignment centres a shorter item on the cross axis" {
    const items = [_]Item{.{ .main = .{ .fixed = 40 }, .cross = 20 }};
    var out: [1]Rect = undefined;
    solve(.{ .axis = .row, .cross_align = .center }, &items, .{ .w = 100, .h = 100 }, &out);
    try approx(out[0].h, 20);
    try approx(out[0].y, 40); // (100 - 20) / 2
}

test "a column stacks items down the vertical axis" {
    const items = [_]Item{ .{ .main = .{ .fixed = 30 } }, .{ .main = .{ .fixed = 30 } } };
    var out: [2]Rect = undefined;
    solve(.{ .axis = .column, .gap = 10 }, &items, .{ .w = 80, .h = 200 }, &out);
    try approx(out[0].y, 0);
    try approx(out[1].y, 40); // 30 + 10 gap
    try approx(out[0].w, 80); // stretched across
}
