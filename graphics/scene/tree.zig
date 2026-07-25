//! The retained scene tree: nodes that persist between frames, each with a transform,
//! bounds, clip, and opacity, and the passes that compose those down the tree into the
//! world-space geometry a compositor draws from.
//!
//! A shell that rebuilt its entire frame from scratch every tick would pay to redraw a
//! still screen, which on a battery device is heat and drain for no visible change. The
//! answer production interfaces reach for is a retained tree: the scene is kept between
//! frames as a tree of nodes, and a frame changes only the nodes that actually moved.
//! For that to work the tree must carry the state a frame needs — where each node sits
//! (its transform), how big it is (its bounds), whether it clips its children, and how
//! opaque it is — and it must be possible to compose a node's own transform with its
//! ancestors' to place it in world space, because a node's real position is the product
//! of every transform above it. This module holds that tree and those composition
//! passes: world transform, world bounds, inherited opacity, and the clip a node is
//! confined to, each a pure function of the tree. What is dirty and what that damages is
//! the next pass's concern; drawing is the compositor's.
//!
//! This module draws nothing. It holds the retained tree and composes ancestor state
//! into world space, as pure functions over the node array.

const std = @import("std");

/// The maximum tree depth a pass will walk. A tree deeper than this is malformed —
/// a real interface nests tens of levels, not thousands — and the bound keeps a
/// pass from following a cycle or a runaway chain without end.
pub const max_depth: usize = 64;

/// Sentinel parent for a root node: it has no parent.
pub const no_parent: u32 = std.math.maxInt(u32);

/// A 2D affine transform, `[a c tx; b d ty; 0 0 1]`. Enough for the translation,
/// scale, and rotation an interface animates; the third row is always `[0 0 1]`.
pub const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub const identity: Transform = .{};

    pub fn translate(x: f32, y: f32) Transform {
        return .{ .tx = x, .ty = y };
    }

    pub fn scale(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .d = sy };
    }

    /// The composition `outer ∘ inner`: apply `inner` first, then `outer`. Composing an
    /// ancestor (outer) with a child (inner) places the child in the ancestor's space.
    pub fn compose(outer: Transform, inner: Transform) Transform {
        return .{
            .a = outer.a * inner.a + outer.c * inner.b,
            .b = outer.b * inner.a + outer.d * inner.b,
            .c = outer.a * inner.c + outer.c * inner.d,
            .d = outer.b * inner.c + outer.d * inner.d,
            .tx = outer.a * inner.tx + outer.c * inner.ty + outer.tx,
            .ty = outer.b * inner.tx + outer.d * inner.ty + outer.ty,
        };
    }

    pub fn apply(transform: Transform, x: f32, y: f32) [2]f32 {
        return .{ transform.a * x + transform.c * y + transform.tx, transform.b * x + transform.d * y + transform.ty };
    }
};

/// An axis-aligned rectangle in some space. Empty when either extent is not positive.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn isEmpty(rect: Rect) bool {
        return rect.width <= 0 or rect.height <= 0;
    }

    pub fn contains(rect: Rect, px: f32, py: f32) bool {
        return px >= rect.x and px < rect.x + rect.width and py >= rect.y and py < rect.y + rect.height;
    }

    /// The overlap of two rectangles, or an empty rectangle if they do not overlap.
    pub fn intersect(rect: Rect, other: Rect) Rect {
        const left = @max(rect.x, other.x);
        const top = @max(rect.y, other.y);
        const right = @min(rect.x + rect.width, other.x + other.width);
        const bottom = @min(rect.y + rect.height, other.y + other.height);
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }

    /// The smallest rectangle containing both. Used to accumulate damage.
    pub fn unionWith(rect: Rect, other: Rect) Rect {
        if (rect.isEmpty()) return other;
        if (other.isEmpty()) return rect;
        const left = @min(rect.x, other.x);
        const top = @min(rect.y, other.y);
        const right = @max(rect.x + rect.width, other.x + other.width);
        const bottom = @max(rect.y + rect.height, other.y + other.height);
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }
};

/// How a node's pixels combine with what is already composited beneath it.
pub const BlendMode = enum {
    /// Source-over: the ordinary case, the layer drawn over the background.
    normal,
    /// Multiplies, darkening — for shadows and tints.
    multiply,
    /// Screens, lightening — for glows and highlights.
    screen,
};

/// One node in the retained tree.
pub const Node = struct {
    /// The parent's index, or `no_parent` for a root. A parent always precedes its
    /// children in the array, so a single forward pass can rely on parents being
    /// resolved first.
    parent: u32 = no_parent,
    /// The node's transform in its parent's space.
    transform: Transform = .identity,
    /// The node's content bounds in its own local space.
    bounds: Rect,
    /// Whether this node clips its descendants to its own bounds.
    clip: bool = false,
    /// The node's own opacity in [0, 1]; multiplied down the tree.
    opacity: f32 = 1,
    /// Whether this node is promoted to its own composited layer.
    is_layer: bool = false,
    /// How this node blends over what is beneath it.
    blend: BlendMode = .normal,
    /// Whether the node's content changed this frame, seeding damage.
    dirty: bool = false,
};

pub const Error = error{
    /// A node's parent does not precede it, or the tree is deeper than the bound.
    Malformed,
};

/// The retained tree: a flat array of nodes with parents earlier than their children.
pub const Tree = struct {
    nodes: []const Node,

    /// Confirms the tree is well formed: every parent precedes its child (which
    /// guarantees acyclicity), and no node is deeper than the bound.
    pub fn validate(tree: Tree) Error!void {
        for (tree.nodes, 0..) |node, index| {
            if (node.parent == no_parent) continue;
            if (node.parent >= index) return error.Malformed; // parent must precede child
            var depth: usize = 0;
            var walk = node.parent;
            while (walk != no_parent) : (depth += 1) {
                if (depth > max_depth) return error.Malformed;
                walk = tree.nodes[walk].parent;
            }
        }
    }

    /// The world transform of a node: the composition of every ancestor transform with
    /// its own, placing its local space in the root's space.
    pub fn worldTransform(tree: Tree, index: usize) Transform {
        var result = tree.nodes[index].transform;
        var parent = tree.nodes[index].parent;
        while (parent != no_parent) {
            result = Transform.compose(tree.nodes[parent].transform, result);
            parent = tree.nodes[parent].parent;
        }
        return result;
    }

    /// The node's local bounds in world space, as an axis-aligned box around the
    /// transformed corners.
    pub fn worldBounds(tree: Tree, index: usize) Rect {
        const transform = tree.worldTransform(index);
        const b = tree.nodes[index].bounds;
        const corners = [_][2]f32{
            transform.apply(b.x, b.y),
            transform.apply(b.x + b.width, b.y),
            transform.apply(b.x, b.y + b.height),
            transform.apply(b.x + b.width, b.y + b.height),
        };
        var min_x: f32 = corners[0][0];
        var min_y: f32 = corners[0][1];
        var max_x: f32 = corners[0][0];
        var max_y: f32 = corners[0][1];
        for (corners[1..]) |corner| {
            min_x = @min(min_x, corner[0]);
            min_y = @min(min_y, corner[1]);
            max_x = @max(max_x, corner[0]);
            max_y = @max(max_y, corner[1]);
        }
        return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
    }

    /// The inherited opacity of a node: the product of its own and every ancestor's,
    /// so a faded container fades its children with it.
    pub fn worldOpacity(tree: Tree, index: usize) f32 {
        var opacity = tree.nodes[index].opacity;
        var parent = tree.nodes[index].parent;
        while (parent != no_parent) {
            opacity *= tree.nodes[parent].opacity;
            parent = tree.nodes[parent].parent;
        }
        return opacity;
    }

    /// The world-space region a node is confined to: the intersection of every
    /// clipping ancestor's world bounds. A node under no clip is confined only by the
    /// (infinite) scene, represented here by the node's own world bounds unclipped.
    pub fn clipRegion(tree: Tree, index: usize) Rect {
        var region: ?Rect = null;
        var parent = tree.nodes[index].parent;
        while (parent != no_parent) {
            if (tree.nodes[parent].clip) {
                const parent_bounds = tree.worldBounds(parent);
                region = if (region) |r| r.intersect(parent_bounds) else parent_bounds;
            }
            parent = tree.nodes[parent].parent;
        }
        return region orelse tree.worldBounds(index);
    }

    /// A node's visible world rectangle: its world bounds intersected with the region
    /// its clipping ancestors confine it to. Empty when clipped entirely away.
    pub fn visibleBounds(tree: Tree, index: usize) Rect {
        return tree.worldBounds(index).intersect(tree.clipRegion(index));
    }
};

// --- Tests ---

const testing = std.testing;

test "world transform composes an ancestor chain" {
    // A child translated (10,0) inside a parent translated (5,5) sits at (15,5).
    const nodes = [_]Node{
        .{ .parent = no_parent, .transform = Transform.translate(5, 5), .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .parent = 0, .transform = Transform.translate(10, 0), .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    try tree.validate();
    const world = tree.worldTransform(1);
    const origin = world.apply(0, 0);
    try testing.expectApproxEqAbs(@as(f32, 15), origin[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5), origin[1], 1e-5);
}

test "world bounds place a scaled node's box in world space" {
    const nodes = [_]Node{
        .{ .parent = no_parent, .transform = Transform.scale(2, 2), .bounds = .{ .x = 0, .y = 0, .width = 50, .height = 50 } },
        .{ .parent = 0, .transform = Transform.translate(10, 10), .bounds = .{ .x = 0, .y = 0, .width = 5, .height = 5 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    // Child at local (10,10) size 5 under a 2x parent -> world origin (20,20), size 10.
    const world = tree.worldBounds(1);
    try testing.expectApproxEqAbs(@as(f32, 20), world.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 10), world.width, 1e-5);
}

test "inherited opacity multiplies down the tree" {
    const nodes = [_]Node{
        .{ .parent = no_parent, .opacity = 0.5, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        .{ .parent = 0, .opacity = 0.5, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    try testing.expectApproxEqAbs(@as(f32, 0.25), tree.worldOpacity(1), 1e-6);
}

test "a clipping ancestor confines a child's visible bounds" {
    const nodes = [_]Node{
        // A clipping container at (0,0) size 20.
        .{ .parent = no_parent, .clip = true, .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
        // A child that extends to (0,0) size 40 — half of it is outside the clip.
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const visible = tree.visibleBounds(1);
    try testing.expectApproxEqAbs(@as(f32, 20), visible.width, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 20), visible.height, 1e-5);
}

test "a malformed tree whose parent follows its child is rejected" {
    const nodes = [_]Node{
        .{ .parent = 1, .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } }, // parent 1 follows this node 0
        .{ .parent = no_parent, .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    try testing.expectError(error.Malformed, tree.validate());
}

test "rectangle intersect and union behave at the edges" {
    const a: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const overlap = a.intersect(b);
    try testing.expectApproxEqAbs(@as(f32, 5), overlap.width, 1e-6);
    const bound = a.unionWith(b);
    try testing.expectApproxEqAbs(@as(f32, 15), bound.width, 1e-6);
    // Disjoint rectangles intersect to empty.
    try testing.expect(a.intersect(.{ .x = 100, .y = 100, .width = 1, .height = 1 }).isEmpty());
}
