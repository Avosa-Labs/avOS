//! Frame diffing: turning the nodes that changed since the last frame into the
//! rectangles that must be repainted, so a frame redraws only what moved and an idle
//! screen redraws nothing at all.
//!
//! The reason to keep a retained tree is to avoid repainting what has not changed, and
//! this is where that saving is actually taken. A node that changed damages two
//! regions, not one: where it used to be, which must be repainted to erase it, and
//! where it is now, which must be repainted to show it. Collecting those regions across
//! every changed node gives the damage — the set of rectangles the renderer must
//! refresh — and everything outside it can be left exactly as it was. The property that
//! makes this worth doing is the quiet one: when nothing changed, the damage is empty,
//! and an empty damage means an idle interface costs no drawing and no power. Damage is
//! coalesced so a handful of nearby changes become one rectangle rather than many,
//! because the cost of a repaint is closer to its bounding box than its exact area.
//!
//! This module repaints nothing. It computes the damage rectangles from a tree and what
//! changed, as a pure function.

const std = @import("std");
const scene = @import("tree.zig");

pub const Rect = scene.Rect;
pub const Tree = scene.Tree;

/// The recorded world bounds a node occupied on the previous frame, so a node that
/// moved can have its old location erased. `null` for a node that did not exist last
/// frame — a newly-added node damages only where it now is.
pub const Previous = ?Rect;

/// A bounded set of damage rectangles. New damage is merged into an existing rectangle
/// when they overlap, so the set stays small; when it is full, further damage is
/// folded into the last rectangle rather than dropped, so the damage is always a
/// superset of what truly changed — never less, which would leave stale pixels.
pub const DamageSet = struct {
    rects: []Rect,
    count: usize = 0,

    pub fn init(buffer: []Rect) DamageSet {
        return .{ .rects = buffer };
    }

    /// Adds a rectangle to the damage, merging it into an overlapping one where
    /// possible. An empty rectangle adds nothing.
    pub fn add(set: *DamageSet, rect: Rect) void {
        if (rect.isEmpty()) return;
        for (set.rects[0..set.count]) |*existing| {
            if (!existing.intersect(rect).isEmpty()) {
                existing.* = existing.unionWith(rect);
                return;
            }
        }
        if (set.count < set.rects.len) {
            set.rects[set.count] = rect;
            set.count += 1;
        } else {
            // Full: fold into the last rectangle so nothing is lost, at the cost of a
            // larger repaint region. Correctness (repaint a superset) over precision.
            set.rects[set.count - 1] = set.rects[set.count - 1].unionWith(rect);
        }
    }

    /// The damage rectangles accumulated so far.
    pub fn damage(set: DamageSet) []const Rect {
        return set.rects[0..set.count];
    }

    /// Whether nothing is damaged — the idle-frame case that costs no repaint.
    pub fn isClean(set: DamageSet) bool {
        return set.count == 0;
    }

    /// Whether a point falls inside any damage rectangle — for a renderer deciding
    /// whether a given surface needs repainting.
    pub fn touches(set: DamageSet, x: f32, y: f32) bool {
        for (set.rects[0..set.count]) |rect| {
            if (rect.contains(x, y)) return true;
        }
        return false;
    }
};

/// Computes the frame's damage from a tree and each node's previous world bounds.
///
/// A node marked dirty damages both where it was (`previous[index]`, if it existed)
/// and where it is now (its current world bounds), so a move erases the old position
/// and paints the new one. A clean node contributes nothing. The result is written
/// into the caller's `DamageSet`, coalesced. When no node is dirty the set stays
/// empty, which is the whole point — an unchanged frame is not redrawn.
pub fn frameDamage(tree: Tree, previous: []const Previous, set: *DamageSet) void {
    for (tree.nodes, 0..) |node, index| {
        if (!node.dirty) continue;
        if (index < previous.len) {
            if (previous[index]) |old| set.add(old);
        }
        set.add(tree.visibleBounds(index));
    }
}

// --- Tests ---

const testing = std.testing;
const Node = scene.Node;
const Transform = scene.Transform;

test "an unchanged frame damages nothing" {
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .parent = 0, .bounds = .{ .x = 10, .y = 10, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    var buffer: [8]Rect = undefined;
    var set = DamageSet.init(&buffer);
    frameDamage(tree, &.{ null, null }, &set);
    try testing.expect(set.isClean()); // nothing dirty -> nothing to repaint
}

test "a moved node damages both where it was and where it is" {
    // The node is now at (30,10); it was at (10,10). Both must repaint.
    const nodes = [_]Node{
        .{ .parent = scene.no_parent, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .parent = 0, .transform = Transform.translate(30, 10), .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .dirty = true },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const previous = [_]Previous{ null, .{ .x = 10, .y = 10, .width = 10, .height = 10 } };
    var buffer: [8]Rect = undefined;
    var set = DamageSet.init(&buffer);
    frameDamage(tree, &previous, &set);
    try testing.expect(!set.isClean());
    // The old region (10,10) and the new region (30,10) are both covered.
    try testing.expect(set.touches(12, 12));
    try testing.expect(set.touches(32, 12));
}

test "overlapping damage is merged into one rectangle" {
    var buffer: [8]Rect = undefined;
    var set = DamageSet.init(&buffer);
    set.add(.{ .x = 0, .y = 0, .width = 20, .height = 20 });
    set.add(.{ .x = 10, .y = 10, .width = 20, .height = 20 }); // overlaps the first
    try testing.expectEqual(@as(usize, 1), set.damage().len);
    // The merged rectangle bounds both.
    const merged = set.damage()[0];
    try testing.expectApproxEqAbs(@as(f32, 30), merged.width, 1e-5);
}

test "disjoint damage stays as separate rectangles" {
    var buffer: [8]Rect = undefined;
    var set = DamageSet.init(&buffer);
    set.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    set.add(.{ .x = 100, .y = 100, .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 2), set.damage().len);
}

test "a full damage set folds rather than dropping, keeping a superset" {
    var buffer: [1]Rect = undefined; // room for exactly one rectangle
    var set = DamageSet.init(&buffer);
    set.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    set.add(.{ .x = 100, .y = 100, .width = 10, .height = 10 }); // no room; folds into the first
    try testing.expectEqual(@as(usize, 1), set.damage().len);
    // The folded rectangle still covers both original regions.
    try testing.expect(set.damage()[0].contains(5, 5));
    try testing.expect(set.damage()[0].contains(105, 105));
}
