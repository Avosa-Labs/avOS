//! Pointer hit-testing: resolving a tap to the interactive target under it.
//!
//! A rendered frame is a stack of rectangles drawn back to front; a tap lands on whichever interactive
//! target is topmost at that point. This module does that resolution: given the frame's interactive
//! targets in draw order and a pointer position, it returns the one the person actually touched — the
//! last (frontmost) target that contains the point, so a button drawn over a card wins over the card
//! beneath it. A tap that hits no target resolves to nothing rather than to the nearest, because acting
//! on a near-miss is how a person ends up triggering something they did not aim at. The result is a
//! target identifier the shell hands to the input decision layer, which decides whether that target may
//! be activated by that input — routing is separated from authority on purpose, so a tap is turned into
//! an intent here and the intent is judged there.
//!
//! This module reads no device. It decides which target a pointer position hits, as a pure function.

const std = @import("std");
const paint = @import("paint.zig");

const Rect = paint.Rect;

/// An interactive target: a rectangle and the identifier the shell knows it by.
pub const Target = struct {
    id: u32,
    rect: Rect,
};

/// Whether a point lies within a rectangle (left/top inclusive, right/bottom exclusive).
pub fn contains(rect: Rect, x: i32, y: i32) bool {
    return x >= rect.x and y >= rect.y and
        x < rect.x + @as(i32, @intCast(rect.w)) and y < rect.y + @as(i32, @intCast(rect.h));
}

/// Resolves a pointer position to the identifier of the frontmost target containing it, or null if the
/// tap hits no target.
///
/// Targets are given in draw order (back to front); the frontmost hit is the last one in the list that
/// contains the point, so an element drawn over another wins. A tap outside every target returns null —
/// never the nearest — so a near-miss activates nothing.
pub fn hit(targets: []const Target, x: i32, y: i32) ?u32 {
    var index = targets.len;
    while (index > 0) {
        index -= 1;
        if (contains(targets[index].rect, x, y)) return targets[index].id;
    }
    return null;
}

const testing = std.testing;

fn target(id: u32, x: i32, y: i32, w: u32, h: u32) Target {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h } };
}

test "a tap inside a target hits it" {
    const targets = [_]Target{target(7, 10, 10, 40, 40)};
    try testing.expectEqual(@as(?u32, 7), hit(&targets, 20, 20));
}

test "a tap outside every target hits nothing" {
    const targets = [_]Target{target(7, 10, 10, 40, 40)};
    try testing.expectEqual(@as(?u32, null), hit(&targets, 100, 100));
}

test "the frontmost overlapping target wins" {
    // The card (id 1) is drawn first, the button (id 2) over it; a tap in the overlap hits the button.
    const targets = [_]Target{
        target(1, 0, 0, 100, 100),
        target(2, 20, 20, 40, 40),
    };
    try testing.expectEqual(@as(?u32, 2), hit(&targets, 30, 30));
    // A tap on the card outside the button still hits the card.
    try testing.expectEqual(@as(?u32, 1), hit(&targets, 5, 5));
}

test "edges are inclusive at the top-left and exclusive at the bottom-right" {
    const targets = [_]Target{target(3, 10, 10, 20, 20)};
    try testing.expectEqual(@as(?u32, 3), hit(&targets, 10, 10)); // top-left corner
    try testing.expectEqual(@as(?u32, null), hit(&targets, 30, 30)); // just past bottom-right
    try testing.expectEqual(@as(?u32, 3), hit(&targets, 29, 29)); // last inside pixel
}

test "a resolved hit always contains the point, swept" {
    // The no-near-miss property: whenever a tap resolves to a target, that target actually contains the
    // point.
    const targets = [_]Target{
        target(1, 0, 0, 30, 30),
        target(2, 40, 0, 30, 30),
        target(3, 0, 40, 30, 30),
    };
    var y: i32 = -5;
    while (y < 80) : (y += 5) {
        var x: i32 = -5;
        while (x < 80) : (x += 5) {
            if (hit(&targets, x, y)) |id| {
                var found = false;
                for (targets) |t| {
                    if (t.id == id) {
                        try testing.expect(contains(t.rect, x, y));
                        found = true;
                    }
                }
                try testing.expect(found);
            }
        }
    }
}
