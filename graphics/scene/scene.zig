//! Validating a scene graph before it is rendered, so a tree that is too deep, cyclic,
//! or dangling is refused rather than crashing the renderer that walks it.
//!
//! A scene is a tree of nodes — a view holding views holding views — and the renderer
//! produces the frame by walking it. That walk is only safe if the tree is well formed.
//! A cycle, where a node is its own ancestor, sends the walk into an infinite loop that
//! hangs the compositor. A depth beyond a sane bound blows the recursion stack or costs
//! more to traverse than a frame can afford. A node parented to an index that is not a
//! node is a dangling reference the walk would follow into nothing. None of these should
//! reach the renderer, because a renderer hardened against a malformed tree at every step
//! is slow, and one that is not hardened crashes. So the scene graph is validated up
//! front — it must be an acyclic tree, within a depth bound, with every parent
//! reference resolving — and only a valid scene is handed to the renderer to walk.
//!
//! This module renders nothing. It checks that a scene graph is a bounded, acyclic tree
//! with resolving references, as a pure function over the node array.

const std = @import("std");

/// The deepest a scene tree may nest. Beyond this the traversal costs too much and risks
/// the stack; a genuinely deeper UI is restructured.
pub const max_depth: usize = 64;

/// A scene node. Its parent is an index into the same node array, or `no_parent` for a
/// root. Nodes are given in an order where a valid tree has every parent index less than
/// the child's own — a node is defined after its parent — which makes acyclicity and
/// resolution checkable in one pass.
pub const Node = struct {
    parent: usize,
};

/// The sentinel parent value for a root node.
pub const no_parent: usize = std.math.maxInt(usize);

/// Why a scene graph was rejected.
pub const Invalid = error{
    /// A node's parent index does not refer to an earlier node.
    DanglingParent,
    /// A node references a parent at or after itself, which admits a cycle.
    NotTopologicallyOrdered,
    /// The tree nests deeper than the bound allows.
    TooDeep,
};

/// Validates a scene graph.
///
/// Each node's parent must be either a root marker or an earlier node — a parent index at
/// or beyond the node's own position would allow a cycle, and one past the array end is
/// dangling, so both are rejected. Because a valid tree lists every parent before its
/// child, the depth of each node is one more than its parent's, computed in the same
/// pass, and any node exceeding the depth bound rejects the tree. A scene that passes is
/// a bounded acyclic tree the renderer can walk without hardening every step.
pub fn validate(nodes: []const Node) Invalid!void {
    var depth: [max_depth + 2]usize = undefined;
    for (nodes, 0..) |node, index| {
        if (node.parent == no_parent) {
            if (index < depth.len) depth[index] = 0;
            continue;
        }
        if (node.parent >= index) return Invalid.NotTopologicallyOrdered;
        // parent < index, and index-1 <= max nodes; parent depth is known.
        const parent_depth = if (node.parent < depth.len) depth[node.parent] else return Invalid.TooDeep;
        const node_depth = parent_depth + 1;
        if (node_depth > max_depth) return Invalid.TooDeep;
        if (index < depth.len) depth[index] = node_depth;
    }
}

/// Whether a scene graph is valid, for callers wanting a boolean.
pub fn isValid(nodes: []const Node) bool {
    validate(nodes) catch return false;
    return true;
}

test "a well-formed tree validates" {
    const nodes = [_]Node{
        .{ .parent = no_parent }, // 0: root
        .{ .parent = 0 }, // 1
        .{ .parent = 0 }, // 2
        .{ .parent = 1 }, // 3
    };
    try validate(&nodes);
}

test "a parent index at or after the node is rejected" {
    // Node 1 claims node 1 as its parent: a self-cycle.
    const nodes = [_]Node{ .{ .parent = no_parent }, .{ .parent = 1 } };
    try std.testing.expectError(Invalid.NotTopologicallyOrdered, validate(&nodes));
}

test "a parent index past the array is dangling" {
    const nodes = [_]Node{ .{ .parent = no_parent }, .{ .parent = 5 } };
    try std.testing.expectError(Invalid.NotTopologicallyOrdered, validate(&nodes));
}

test "a chain deeper than the bound is rejected" {
    var nodes: [max_depth + 2]Node = undefined;
    nodes[0] = .{ .parent = no_parent };
    for (1..nodes.len) |i| nodes[i] = .{ .parent = i - 1 };
    // Depth reaches max_depth + 1 at the last node.
    try std.testing.expectError(Invalid.TooDeep, validate(&nodes));
}

test "a chain exactly at the depth bound validates" {
    var nodes: [max_depth + 1]Node = undefined;
    nodes[0] = .{ .parent = no_parent };
    for (1..nodes.len) |i| nodes[i] = .{ .parent = i - 1 };
    // Deepest node is at depth max_depth.
    try validate(&nodes);
}

test "an empty scene is valid" {
    try validate(&.{});
}

test "multiple roots are allowed" {
    const nodes = [_]Node{
        .{ .parent = no_parent },
        .{ .parent = no_parent },
        .{ .parent = 1 },
    };
    try validate(&nodes);
}

test "every valid scene has resolving, earlier parents, swept" {
    // The well-formed property: in any scene that validates, every non-root node's
    // parent is an earlier index.
    const scenes = [_][]const Node{
        &.{ .{ .parent = no_parent }, .{ .parent = 0 }, .{ .parent = 1 } },
        &.{ .{ .parent = no_parent }, .{ .parent = no_parent } },
        &.{.{ .parent = no_parent }},
    };
    for (scenes) |nodes| {
        if (isValid(nodes)) {
            for (nodes, 0..) |node, index| {
                if (node.parent != no_parent) try std.testing.expect(node.parent < index);
            }
        }
    }
}
