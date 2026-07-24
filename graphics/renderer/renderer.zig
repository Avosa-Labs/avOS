//! Deciding whether a frame's draw work fits within its budget, so a frame that would
//! ask for more than can be drawn in time is trimmed rather than blowing the frame
//! deadline and stuttering.
//!
//! A frame has a deadline — sixteen milliseconds at sixty hertz — and everything drawn
//! in it competes for that time. Draw calls are not free: each has a fixed cost to set
//! up, and past a certain number a frame cannot finish before its deadline, so it either
//! drops (a visible stutter) or runs long (a visible hitch). A renderer that accepts
//! unbounded draw calls hands the frame an impossible amount of work and the person sees
//! the result as jank. So the renderer bounds the work per frame: there is a cap on draw
//! calls, and content beyond it is deferred to a later frame rather than crammed into
//! this one. A single primitive that is itself too large is clipped to the visible
//! viewport, because rasterizing pixels outside the screen is time spent on what no one
//! will see. The frame stays inside its budget, and motion stays smooth.
//!
//! This module rasterizes nothing. It decides whether a draw request fits the frame's
//! remaining budget, as a pure function over the counts.

const std = @import("std");

/// The most draw calls a frame may issue before it risks its deadline. A ceiling chosen
/// so a full frame of calls completes within the budget on the reference device.
pub const max_draw_calls: u32 = 4096;

/// A frame's draw accounting.
pub const Frame = struct {
    /// Draw calls already issued this frame.
    issued: u32,
};

/// The outcome of a draw request.
pub const Decision = enum {
    /// The draw fits this frame and is issued.
    issue,
    /// The frame is at its draw-call cap; the draw is deferred to a later frame rather
    /// than blowing the deadline.
    defer_to_next_frame,

    pub fn issues(decision: Decision) bool {
        return decision == .issue;
    }
};

/// Decides whether a draw call may be issued this frame.
///
/// While the frame is below its draw-call cap the call is issued; at the cap it is
/// deferred to a later frame, so the current frame's work stays within what can be drawn
/// before its deadline. Deferring keeps motion smooth: content appears a frame later
/// rather than making every frame late.
pub fn admitDraw(frame: Frame) Decision {
    if (frame.issued >= max_draw_calls) return .defer_to_next_frame;
    return .issue;
}

/// An axis-aligned rectangle.
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

/// Clips a primitive's rectangle to the viewport, returning the visible intersection or
/// null if the primitive is entirely offscreen.
///
/// Rasterizing pixels outside the viewport is time spent on what no one sees, so a
/// primitive is clipped to the visible region before it is drawn, and one that lies
/// wholly offscreen is dropped rather than drawn and discarded.
pub fn clipToViewport(primitive: Rect, viewport: Rect) ?Rect {
    const left = @max(primitive.x, viewport.x);
    const top = @max(primitive.y, viewport.y);
    const right = @min(@as(i64, primitive.x) + primitive.width, @as(i64, viewport.x) + viewport.width);
    const bottom = @min(@as(i64, primitive.y) + primitive.height, @as(i64, viewport.y) + viewport.height);
    if (right <= left or bottom <= top) return null; // entirely offscreen
    return .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

test "a draw within the cap is issued" {
    try std.testing.expectEqual(Decision.issue, admitDraw(.{ .issued = 100 }));
}

test "a draw at the cap is deferred" {
    try std.testing.expectEqual(Decision.defer_to_next_frame, admitDraw(.{ .issued = max_draw_calls }));
}

test "a primitive inside the viewport is unchanged" {
    const viewport: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const primitive: Rect = .{ .x = 100, .y = 100, .width = 200, .height = 200 };
    const clipped = clipToViewport(primitive, viewport).?;
    try std.testing.expectEqual(@as(i32, 100), clipped.x);
    try std.testing.expectEqual(@as(u32, 200), clipped.width);
}

test "a primitive straddling the edge is clipped to the visible part" {
    const viewport: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };
    const primitive: Rect = .{ .x = 900, .y = 900, .width = 400, .height = 400 };
    const clipped = clipToViewport(primitive, viewport).?;
    try std.testing.expectEqual(@as(u32, 100), clipped.width); // 1000 - 900
    try std.testing.expectEqual(@as(u32, 100), clipped.height);
}

test "a fully offscreen primitive is dropped" {
    const viewport: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };
    const primitive: Rect = .{ .x = 2000, .y = 2000, .width = 100, .height = 100 };
    try std.testing.expectEqual(@as(?Rect, null), clipToViewport(primitive, viewport));
}

test "no frame ever issues past its draw-call cap, swept" {
    // The deadline property: while issuing draws up to and beyond the cap, no draw is
    // issued once the count reaches the cap.
    var issued: u32 = max_draw_calls - 3;
    while (issued <= max_draw_calls + 3) : (issued += 1) {
        const decision = admitDraw(.{ .issued = issued });
        if (decision.issues()) try std.testing.expect(issued < max_draw_calls);
    }
}

test "a clipped rectangle never exceeds the viewport, swept" {
    const viewport: Rect = .{ .x = 0, .y = 0, .width = 500, .height = 500 };
    const positions = [_]i32{ -100, 0, 250, 490, 600 };
    for (positions) |px| {
        for (positions) |py| {
            const primitive: Rect = .{ .x = px, .y = py, .width = 200, .height = 200 };
            if (clipToViewport(primitive, viewport)) |clipped| {
                try std.testing.expect(clipped.x >= viewport.x and clipped.y >= viewport.y);
                try std.testing.expect(@as(i64, clipped.x) + clipped.width <= viewport.width);
                try std.testing.expect(@as(i64, clipped.y) + clipped.height <= viewport.height);
            }
        }
    }
}
