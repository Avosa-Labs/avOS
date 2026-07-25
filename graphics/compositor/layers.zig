//! Walking the retained tree into the ordered list of layers a device actually
//! composites: each with its clipped world rectangle, inherited opacity, and blend
//! mode, in back-to-front order, with the invisible ones dropped.
//!
//! The retained tree says what exists; compositing decides what is drawn and in what
//! order. A node is composited over what is beneath it, so paint order is the tree in
//! order — a parent before its children, earlier siblings before later — and that
//! order is what this pass emits. Along the way it resolves the things a compositor
//! must know per layer and a node only knows locally: the rectangle the layer occupies
//! after every clipping ancestor has confined it, the opacity it inherits from every
//! ancestor multiplied by its own, and how it blends. And it drops what cannot be seen
//! — a layer clipped to nothing, or faded to full transparency — because the cheapest
//! layer is the one never handed to the device. What is left is a flat, ordered draw
//! list: the exact work a frame is, and no more.
//!
//! This module composites nothing itself. It flattens the retained tree into an ordered
//! list of visible layers, as a pure pass over the tree.

const std = @import("std");
const scene = @import("../scene/tree.zig");

pub const Rect = scene.Rect;
pub const Tree = scene.Tree;
pub const BlendMode = scene.BlendMode;

/// Below this inherited opacity a layer contributes nothing a viewer could see, so it
/// is dropped rather than composited.
pub const min_visible_opacity: f32 = 1.0 / 512.0;

/// What a flattened frame is being composited for: the physical screen a person
/// looks at, or a capture — a screenshot or recording — that leaves the device's
/// display. The difference is not cosmetic: a protected layer is drawn to the screen
/// and withheld from a capture, and that decision has to be made here, at the one
/// boundary every rendered frame crosses, or it is not enforced at all.
pub const Target = enum {
    /// The physical display. Everything visible is composited.
    screen,
    /// A screenshot or screen recording. Protected layers are withheld.
    capture,
};

/// One composited layer: which node it is, the clipped rectangle it occupies in world
/// space, the opacity it is drawn at, how it blends, and whether it is protected.
pub const Layer = struct {
    node: usize,
    bounds: Rect,
    opacity: f32,
    blend: BlendMode,
    secure: bool,
};

/// Flattens the tree into the ordered list of layers to composite for the screen.
pub fn flatten(tree: Tree, buffer: []Layer) []const Layer {
    return flattenForTarget(tree, buffer, .screen);
}

/// Flattens the tree into the ordered draw list for a target, back to front.
///
/// Every node is considered in tree order, which is paint order. A node whose visible
/// bounds are empty — clipped entirely away — or whose inherited opacity is below the
/// visible floor is skipped, because compositing it would cost work for no visible
/// result. And when the target is a capture, a protected node is withheld entirely: a
/// screenshot or recording never receives a secure layer, enforced here at the
/// composite boundary rather than trusted to a policy elsewhere. The rest are written
/// into `buffer` and the filled prefix is returned.
pub fn flattenForTarget(tree: Tree, buffer: []Layer, target: Target) []const Layer {
    var count: usize = 0;
    for (tree.nodes, 0..) |node, index| {
        if (count >= buffer.len) break;
        // The security enforcement: a protected layer is never composited into a
        // capture. On screen it is drawn normally.
        if (target == .capture and node.secure) continue;
        const opacity = tree.worldOpacity(index);
        if (opacity < min_visible_opacity) continue;
        const bounds = tree.visibleBounds(index);
        if (bounds.isEmpty()) continue;
        buffer[count] = .{
            .node = index,
            .bounds = bounds,
            .opacity = opacity,
            .blend = node.blend,
            .secure = node.secure,
        };
        count += 1;
    }
    return buffer[0..count];
}

/// Whether any layer in a list is protected — for a caller confirming a capture path
/// carries no secure content before it encodes.
pub fn containsSecure(layers: []const Layer) bool {
    for (layers) |layer| {
        if (layer.secure) return true;
    }
    return false;
}

/// Whether an upper layer, fully opaque and normal-blended, completely covers a lower
/// one — in which case the lower one need not be drawn. Conservative: a layer is
/// declared covered only when the cover is opaque, blends normally, and contains the
/// lower rectangle entirely, because any transparency or a non-normal blend lets the
/// lower layer show through.
pub fn covers(upper: Layer, lower: Layer) bool {
    if (upper.opacity < 1 or upper.blend != .normal) return false;
    const u = upper.bounds;
    const l = lower.bounds;
    return l.x >= u.x and l.y >= u.y and
        l.x + l.width <= u.x + u.width and
        l.y + l.height <= u.y + u.height;
}

/// Whether a layer is occluded by any later (higher) layer in the list, so a caller
/// can cull it. Only layers drawn after it — above it — can occlude it.
pub fn occluded(layers: []const Layer, index: usize) bool {
    for (layers[index + 1 ..]) |upper| {
        if (covers(upper, layers[index])) return true;
    }
    return false;
}

// --- Tests ---

const testing = std.testing;
const Node = scene.Node;
const Transform = scene.Transform;

test "flatten emits nodes in back-to-front paint order" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        .{ .parent = 0, .bounds = .{ .x = 20, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    var buffer: [8]Layer = undefined;
    const layers = flatten(tree, &buffer);
    try testing.expectEqual(@as(usize, 3), layers.len);
    // Order is the tree order: root, then its children in array order.
    try testing.expectEqual(@as(usize, 0), layers[0].node);
    try testing.expectEqual(@as(usize, 1), layers[1].node);
    try testing.expectEqual(@as(usize, 2), layers[2].node);
}

test "a fully transparent subtree is dropped from the draw list" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .opacity = 0, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } }, // inherits 0 opacity
    };
    const tree: Tree = .{ .nodes = &nodes };
    var buffer: [8]Layer = undefined;
    const layers = flatten(tree, &buffer);
    try testing.expectEqual(@as(usize, 0), layers.len);
}

test "a layer clipped entirely away is dropped" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .clip = true, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        // A child entirely outside the clip region.
        .{ .parent = 0, .transform = Transform.translate(100, 100), .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    var buffer: [8]Layer = undefined;
    const layers = flatten(tree, &buffer);
    // Only the clipping container itself is visible; the child is clipped out.
    try testing.expectEqual(@as(usize, 1), layers.len);
    try testing.expectEqual(@as(usize, 0), layers[0].node);
}

test "an opaque layer occludes one it fully covers, but not a peeking one" {
    const covered: Layer = .{ .node = 0, .bounds = .{ .x = 10, .y = 10, .width = 10, .height = 10 }, .opacity = 1, .blend = .normal, .secure = false };
    const cover: Layer = .{ .node = 1, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .opacity = 1, .blend = .normal, .secure = false };
    try testing.expect(covers(cover, covered));

    // A translucent cover never occludes.
    var translucent = cover;
    translucent.opacity = 0.5;
    try testing.expect(!covers(translucent, covered));

    // A cover that does not fully contain the lower layer never occludes it.
    const partial: Layer = .{ .node = 2, .bounds = .{ .x = 0, .y = 0, .width = 15, .height = 100 }, .opacity = 1, .blend = .normal, .secure = false };
    try testing.expect(!covers(partial, covered));
}

test "occlusion looks only at layers drawn above" {
    const layers = [_]Layer{
        .{ .node = 0, .bounds = .{ .x = 10, .y = 10, .width = 10, .height = 10 }, .opacity = 1, .blend = .normal, .secure = false },
        .{ .node = 1, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .opacity = 1, .blend = .normal, .secure = false },
    };
    // Layer 0 is covered by layer 1 which is drawn after it.
    try testing.expect(occluded(&layers, 0));
    // The top layer is occluded by nothing.
    try testing.expect(!occluded(&layers, 1));
}

test "a protected layer is drawn to the screen but withheld from a capture" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        // A protected node: a payment sheet, say.
        .{ .parent = 0, .secure = true, .bounds = .{ .x = 10, .y = 10, .width = 50, .height = 50 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    var buffer: [8]Layer = undefined;

    // On screen, the protected layer is composited.
    const on_screen = flattenForTarget(tree, &buffer, .screen);
    try testing.expectEqual(@as(usize, 2), on_screen.len);
    try testing.expect(containsSecure(on_screen));

    // Into a capture, it is withheld — the screenshot never receives it.
    var capture_buffer: [8]Layer = undefined;
    const captured = flattenForTarget(tree, &capture_buffer, .capture);
    try testing.expectEqual(@as(usize, 1), captured.len);
    try testing.expect(!containsSecure(captured));
}
