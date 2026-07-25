//! Finding which node a point lands on, over the same retained tree the compositor
//! draws, so what a person touches is exactly what they see — topmost first, clipped
//! the way it was drawn.
//!
//! Hit-testing has to agree with compositing or the interface lies: a tap must land on
//! the control the person sees on top, not one hidden beneath it, and not on part of a
//! control that was clipped away and never shown. The only way to keep the two in
//! agreement is to test against the same tree that was drawn, with the same world
//! transforms and the same clipping. So a hit walks the drawn layers from front to
//! back — the reverse of paint order, because the last thing drawn is the top thing
//! touched — and returns the first whose visible, clipped world rectangle contains the
//! point. A node clipped to nothing can never be hit, exactly as it can never be seen.
//! Interactivity is a property some nodes carry and others do not, so a purely
//! decorative layer is passed through to whatever sits behind it.
//!
//! This module dispatches nothing. It finds the node a point hits, as a pure query
//! over the retained tree.

const std = @import("std");
const scene = @import("tree.zig");

pub const Tree = scene.Tree;
pub const Rect = scene.Rect;

/// Which nodes may receive a hit. A decorative node is skipped so the point falls
/// through to whatever interactive node sits behind it.
pub const Interactive = struct {
    context: *const anyopaque,
    /// Whether the node at this index can be hit. Lets the caller keep interactivity
    /// out of the geometry and decide it however it likes.
    is_interactive: *const fn (context: *const anyopaque, index: usize) bool,

    fn allows(self: Interactive, index: usize) bool {
        return self.is_interactive(self.context, index);
    }
};

/// A predicate that treats every node as interactive, for a tree whose nodes are all
/// hittable.
pub const all_interactive: Interactive = .{ .context = undefined, .is_interactive = alwaysTrue };
fn alwaysTrue(_: *const anyopaque, _: usize) bool {
    return true;
}

/// The topmost node whose visible world rectangle contains the point, or null if the
/// point lands on nothing hittable.
///
/// The tree is walked front to back — the reverse of the paint order the compositor
/// uses — because a hit belongs to the last thing drawn over that spot. A node's
/// *visible* bounds are tested, so a node clipped away cannot be hit any more than it
/// can be seen; and a node the predicate calls non-interactive is passed over so the
/// point reaches whatever is behind it.
pub fn hit(tree: Tree, x: f32, y: f32, interactive: Interactive) ?usize {
    var index = tree.nodes.len;
    while (index > 0) {
        index -= 1;
        if (!interactive.allows(index)) continue;
        if (tree.visibleBounds(index).contains(x, y)) return index;
    }
    return null;
}

// --- Tests ---

const testing = std.testing;
const Node = scene.Node;
const Transform = scene.Transform;

fn onlyThese(comptime indices: []const usize) Interactive {
    const Filter = struct {
        fn is(_: *const anyopaque, index: usize) bool {
            inline for (indices) |allowed| {
                if (index == allowed) return true;
            }
            return false;
        }
    };
    return .{ .context = undefined, .is_interactive = Filter.is };
}

test "a hit lands on the topmost node over the point" {
    // Two overlapping children; the later one is drawn on top and should win a hit.
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .parent = 0, .bounds = .{ .x = 10, .y = 10, .width = 40, .height = 40 } },
        .{ .parent = 0, .bounds = .{ .x = 20, .y = 20, .width = 40, .height = 40 } }, // on top where they overlap
    };
    const tree: Tree = .{ .nodes = &nodes };
    // Point (30,30) is inside both children; the topmost (node 2) wins.
    try testing.expectEqual(@as(?usize, 2), hit(tree, 30, 30, all_interactive));
    // A point only in the lower child hits it.
    try testing.expectEqual(@as(?usize, 1), hit(tree, 12, 12, all_interactive));
}

test "a point outside every node hits nothing" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    try testing.expectEqual(@as(?usize, null), hit(tree, 50, 50, all_interactive));
}

test "a clipped-away node cannot be hit" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .clip = true, .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
        // A child at (100,100), entirely outside the clip — invisible and unhittable.
        .{ .parent = 0, .transform = Transform.translate(100, 100), .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    // A point where the child would be, were it not clipped, hits nothing there.
    try testing.expectEqual(@as(?usize, null), hit(tree, 110, 110, all_interactive));
}

test "a non-interactive node is passed through to what is behind it" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } }, // interactive background
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } }, // decorative overlay on top
    };
    const tree: Tree = .{ .nodes = &nodes };
    // Only node 0 is interactive; the decorative overlay (node 1) is passed through.
    try testing.expectEqual(@as(?usize, 0), hit(tree, 50, 50, onlyThese(&.{0})));
}
