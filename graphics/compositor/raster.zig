//! The software compositor: composites each layer's display list into the frame.
//!
//! The retained tree says what exists and `layers` flattens it into the ordered, culled list
//! of what is drawn. This is the step that actually draws it: every node's content is a
//! display list — the paint commands for that node, authored in the node's own local space —
//! and the compositor is the one place those lists are turned into pixels. It walks the
//! flattened layers back to front, skips a layer that a higher opaque layer fully covers
//! (its pixels would be overwritten), renders each surviving layer's list into a layer buffer,
//! and composites that buffer into the frame at the layer's world position, clipped to its
//! clip region, at its inherited opacity, blended by its mode. So a node never paints straight
//! to the screen; it hands the compositor a display list and the compositor owns the frame.
//!
//! This is the software path — translation, clip, opacity, and blend, which is what the
//! designed surfaces need. Arbitrary scale and rotation of vector content are the GPU adapter's
//! job; here a layer is placed at its world origin.

const std = @import("std");
const paint = @import("../paint/paint.zig");
const framebuffer = @import("../paint/framebuffer.zig");
const tree_mod = @import("../scene/tree.zig");
const layers_mod = @import("layers.zig");

pub const Framebuffer = framebuffer.Framebuffer;
pub const Rect = tree_mod.Rect;
pub const Tree = tree_mod.Tree;
pub const Layer = layers_mod.Layer;
pub const Target = layers_mod.Target;
pub const BlendMode = tree_mod.BlendMode;

/// A node's drawable content: paint commands in the node's own local space (origin at the
/// node's top-left). An empty list is a node that only groups or clips its children.
pub const DisplayList = []const paint.Command;

/// Composites the visible layers of `tree` into `target`. `lists[i]` is node `i`'s display
/// list; `layer_buffer` sizes the flatten pass. Layers are drawn back to front, a layer a
/// higher opaque layer fully covers is dropped, and each is placed at its world position,
/// clipped to its clip region, drawn at its inherited opacity, and blended by its mode.
pub fn composite(
    gpa: std.mem.Allocator,
    target: *Framebuffer,
    tree: Tree,
    lists: []const DisplayList,
    layer_buffer: []Layer,
    target_kind: Target,
) !void {
    const flat = layers_mod.flattenForTarget(tree, layer_buffer, target_kind);
    for (flat, 0..) |layer, i| {
        // Occlusion: a layer fully covered by a later (higher) opaque, normal-blended layer
        // contributes nothing — every pixel is overwritten — so it is not drawn at all.
        var covered = false;
        var above = i + 1;
        while (above < flat.len) : (above += 1) {
            if (layers_mod.covers(flat[above], layer)) {
                covered = true;
                break;
            }
        }
        if (covered) continue;

        const list = lists[layer.node];
        if (list.len == 0) continue;
        try compositeLayer(gpa, target, tree, layer, list);
    }
}

/// Renders one layer's list into a layer buffer, then composites that buffer into the frame.
fn compositeLayer(gpa: std.mem.Allocator, target: *Framebuffer, tree: Tree, layer: Layer, list: DisplayList) !void {
    const box = tree.worldBounds(layer.node); // the node's content box in world space
    const w: u32 = @intFromFloat(@ceil(box.width));
    const h: u32 = @intFromFloat(@ceil(box.height));
    if (w == 0 or h == 0) return;

    var buffer = try Framebuffer.init(gpa, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer buffer.deinit();
    paint.paint(&buffer, list); // the list is authored from the layer's own origin

    const origin_x: i32 = @intFromFloat(@round(box.x));
    const origin_y: i32 = @intFromFloat(@round(box.y));
    blit(target, buffer, origin_x, origin_y, layer.bounds, layer.opacity, layer.blend);
}

/// Composites a layer buffer into `target` at `(origin_x, origin_y)`, clipped to `clip`
/// (world space), scaled by `opacity`, blended by `mode`. Integer source-over with the same
/// rounding the framebuffer uses, so the normal path matches a direct blend exactly.
fn blit(target: *Framebuffer, src: Framebuffer, origin_x: i32, origin_y: i32, clip: Rect, opacity: f32, mode: BlendMode) void {
    const alpha_scale: u32 = @intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 255));
    var y: u32 = 0;
    while (y < src.height) : (y += 1) {
        const ty = origin_y + @as(i32, @intCast(y));
        if (ty < 0 or ty >= target.height) continue;
        var x: u32 = 0;
        while (x < src.width) : (x += 1) {
            const tx = origin_x + @as(i32, @intCast(x));
            if (tx < 0 or tx >= target.width) continue;
            if (!clip.contains(@floatFromInt(tx), @floatFromInt(ty))) continue;

            const source = src.get(x, y);
            const coverage = (@as(u32, source.a) * alpha_scale + 127) / 255; // effective source alpha
            if (coverage == 0) continue;

            const dst = target.get(@intCast(tx), @intCast(ty));
            const inv = 255 - coverage;
            const r = mixChannel(mode, dst.r, source.r);
            const g = mixChannel(mode, dst.g, source.g);
            const b = mixChannel(mode, dst.b, source.b);
            target.set(@intCast(tx), @intCast(ty), .{
                .r = @intCast((r * coverage + @as(u32, dst.r) * inv + 127) / 255),
                .g = @intCast((g * coverage + @as(u32, dst.g) * inv + 127) / 255),
                .b = @intCast((b * coverage + @as(u32, dst.b) * inv + 127) / 255),
                .a = @intCast(coverage + @as(u32, dst.a) * inv / 255),
            });
        }
    }
}

/// One channel of the blend function at full source coverage: how the source combines with
/// what is already composited, before the source's alpha weighs it in.
fn mixChannel(mode: BlendMode, dst: u8, src: u8) u32 {
    return switch (mode) {
        .normal => src,
        .multiply => (@as(u32, dst) * @as(u32, src) + 127) / 255,
        .screen => 255 - ((@as(u32, 255 - dst) * @as(u32, 255 - src) + 127) / 255),
    };
}

// --- Tests ---

const testing = std.testing;
const Node = tree_mod.Node;

fn solidList(rect: paint.Rect, colour: framebuffer.Rgba) [1]paint.Command {
    return .{.{ .solid = .{ .rect = rect, .colour = colour } }};
}

test "layers composite back to front at their world positions" {
    // A red background node, and a blue node translated to (20,20) sized 10x10.
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
        .{ .parent = 0, .transform = tree_mod.Transform.translate(20, 20), .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };

    const bg = solidList(.{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const fg = solidList(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 0, .g = 0, .b = 200, .a = 255 });
    const lists = [_]DisplayList{ &bg, &fg };

    var target = try Framebuffer.init(testing.allocator, 40, 40, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    var layer_buf: [8]Layer = undefined;
    try composite(testing.allocator, &target, tree, &lists, &layer_buf, .screen);

    try testing.expectEqual(@as(u8, 200), target.get(5, 5).r); // background red where uncovered
    try testing.expectEqual(@as(u8, 200), target.get(25, 25).b); // blue node at its world offset
    try testing.expectEqual(@as(u8, 0), target.get(25, 25).r); // and it is over the red
}

test "a layer a higher opaque layer fully covers is not drawn" {
    // Two same-sized nodes; the upper one fully covers the lower with an opaque fill.
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
        .{ .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const lower = solidList(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const upper = solidList(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ .r = 0, .g = 200, .b = 0, .a = 255 });
    const lists = [_]DisplayList{ &lower, &upper };

    var target = try Framebuffer.init(testing.allocator, 20, 20, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    var layer_buf: [8]Layer = undefined;
    try composite(testing.allocator, &target, tree, &lists, &layer_buf, .screen);

    // Only the upper (green) survived; the covered red never reached the frame.
    try testing.expectEqual(@as(u8, 200), target.get(10, 10).g);
    try testing.expectEqual(@as(u8, 0), target.get(10, 10).r);
}

test "a layer's opacity blends its content toward the background" {
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .opacity = 0.5 },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const list = solidList(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const lists = [_]DisplayList{&list};

    var target = try Framebuffer.init(testing.allocator, 10, 10, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    var layer_buf: [8]Layer = undefined;
    try composite(testing.allocator, &target, tree, &lists, &layer_buf, .screen);

    // White at half opacity over black is mid-grey.
    const p = target.get(5, 5);
    try testing.expect(p.r >= 126 and p.r <= 129);
}

test "content outside a node's clip region is not composited" {
    // A clipping parent 10 wide; a child that draws 20 wide. The overflow is clipped away.
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .clip = true },
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const empty = [_]paint.Command{};
    const child = solidList(.{ .x = 0, .y = 0, .w = 20, .h = 10 }, .{ .r = 0, .g = 0, .b = 200, .a = 255 });
    const lists = [_]DisplayList{ &empty, &child };

    var target = try Framebuffer.init(testing.allocator, 20, 10, .{ .r = 30, .g = 30, .b = 30, .a = 255 });
    defer target.deinit();
    var layer_buf: [8]Layer = undefined;
    try composite(testing.allocator, &target, tree, &lists, &layer_buf, .screen);

    try testing.expectEqual(@as(u8, 200), target.get(5, 5).b); // inside the clip: drawn
    try testing.expectEqual(@as(u8, 30), target.get(15, 5).r); // outside the clip: untouched background
}
