//! Encoding the compositor's display lists as GPU quads — the primitive list a GPU device draws.
//!
//! The software rasteriser (raster.zig) walks the flattened, culled layers and paints each layer's
//! display list into the frame at its world origin. The GPU device draws the same frame a different
//! way: it batches the layers' primitives into one pass. The design's four paint commands are all
//! one shape to the GPU — a rounded rectangle, with a zero radius for a sharp fill and equal
//! top/bottom colours for a solid one — so this encodes a tree and its display lists into an
//! ordered list of world-space quads, using the same occlusion cull the software path uses and
//! folding each layer's opacity into the quad's alpha.
//!
//! It draws nothing and needs no GPU: it is the pure translation the Vulkan adapter consumes, so
//! the mapping from the compositor's primitives to the device's is testable on its own, on every
//! lane, without a device present. What the device still owes on top of this list is confining each
//! quad to its `clip` rectangle (a scissor) and the non-`normal` blend modes, which the source-over
//! pipeline does not yet carry; a quad records its clip and this module drops nothing for blend, so
//! those remain the adapter's to honour.

const std = @import("std");
const paint = @import("../paint/paint.zig");
const framebuffer = @import("../paint/framebuffer.zig");
const scene = @import("../scene/tree.zig");
const layers_mod = @import("layers.zig");

pub const Rect = scene.Rect;
pub const Tree = scene.Tree;
pub const Layer = layers_mod.Layer;
pub const Target = layers_mod.Target;
const Rgba = framebuffer.Rgba;

/// A node's drawable content: paint commands in the node's own local space — the same slice
/// `raster.composite` consumes.
pub const DisplayList = []const paint.Command;

/// One GPU quad in world-space pixels: a rounded rectangle with a vertical gradient (equal colours
/// for a solid fill, zero radius for a sharp one), the clip rectangle the device must confine it
/// to, and colours as normalised f32 with the layer's opacity already folded into alpha.
pub const Quad = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,
    top: [4]f32,
    bottom: [4]f32,
    clip: Rect,
};

/// Encodes the visible layers of `tree` into an ordered list of world-space quads, back to front,
/// dropping a layer a higher opaque layer fully covers — the same cull `raster.composite` applies.
/// `lists[i]` is node `i`'s display list; `layer_buffer` sizes the flatten pass. The returned slice
/// is owned by `gpa`.
pub fn encode(
    gpa: std.mem.Allocator,
    tree: Tree,
    lists: []const DisplayList,
    layer_buffer: []Layer,
    target_kind: Target,
) ![]Quad {
    var quads: std.ArrayList(Quad) = .empty;
    errdefer quads.deinit(gpa);

    const flat = layers_mod.flattenForTarget(tree, layer_buffer, target_kind);
    for (flat, 0..) |layer, i| {
        // The same occlusion rule the software path uses: a layer a later opaque, normal-blended
        // layer fully covers contributes nothing, so it is not encoded at all.
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
        if (list.len == 0) continue; // a node that only groups or clips its children

        // The list is authored from the node's own origin; place it at the node's world origin,
        // rounded the way the software blit rounds it, so the two paths land the same pixels.
        const box = tree.worldBounds(layer.node);
        const ox = @round(box.x);
        const oy = @round(box.y);
        for (list) |command| {
            try quads.append(gpa, encodeCommand(command, ox, oy, layer.opacity, layer.bounds));
        }
    }
    return quads.toOwnedSlice(gpa);
}

/// Reduces one paint command to a quad: all four commands are a rounded rectangle to the GPU.
fn encodeCommand(command: paint.Command, ox: f32, oy: f32, opacity: f32, clip: Rect) Quad {
    return switch (command) {
        .solid => |c| quad(c.rect, 0, c.colour, c.colour, ox, oy, opacity, clip),
        .vgradient => |c| quad(c.rect, 0, c.top, c.bottom, ox, oy, opacity, clip),
        .rounded => |c| quad(c.rect, c.radius, c.colour, c.colour, ox, oy, opacity, clip),
        .rounded_vgradient => |c| quad(c.rect, c.radius, c.top, c.bottom, ox, oy, opacity, clip),
    };
}

fn quad(rect: paint.Rect, radius: u32, top: Rgba, bottom: Rgba, ox: f32, oy: f32, opacity: f32, clip: Rect) Quad {
    return .{
        .x = ox + @as(f32, @floatFromInt(rect.x)),
        .y = oy + @as(f32, @floatFromInt(rect.y)),
        .width = @floatFromInt(rect.w),
        .height = @floatFromInt(rect.h),
        .radius = @floatFromInt(radius),
        .top = norm(top, opacity),
        .bottom = norm(bottom, opacity),
        .clip = clip,
    };
}

/// An 8-bit colour to normalised f32, with the layer's opacity folded into alpha — the source-over
/// pipeline reads alpha, so an inherited opacity becomes a weaker source exactly as the software
/// blit scales coverage by it.
fn norm(c: Rgba, opacity: f32) [4]f32 {
    const scale = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt(c.r)) * scale,
        @as(f32, @floatFromInt(c.g)) * scale,
        @as(f32, @floatFromInt(c.b)) * scale,
        @as(f32, @floatFromInt(c.a)) * scale * std.math.clamp(opacity, 0, 1),
    };
}

// --- Tests (pure; no GPU, so they run on every lane) ---

const testing = std.testing;
const Node = scene.Node;
const Transform = scene.Transform;

fn solidList(rect: paint.Rect, colour: Rgba) [1]paint.Command {
    return .{.{ .solid = .{ .rect = rect, .colour = colour } }};
}

test "each layer's commands are placed at the layer's world origin, back to front" {
    // A background node, and a foreground node translated to (20,20).
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
        .{ .parent = 0, .transform = Transform.translate(20, 20), .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };

    const bg = solidList(.{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const fg = solidList(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 0, .g = 0, .b = 200, .a = 255 });
    const lists = [_]DisplayList{ &bg, &fg };

    var layer_buf: [8]Layer = undefined;
    const quads = try encode(testing.allocator, tree, &lists, &layer_buf, .screen);
    defer testing.allocator.free(quads);

    try testing.expectEqual(@as(usize, 2), quads.len);
    try testing.expectEqual(@as(f32, 0), quads[0].x); // background at the origin
    try testing.expectEqual(@as(f32, 20), quads[1].x); // foreground at its world offset
    try testing.expectEqual(@as(f32, 20), quads[1].y);
    try testing.expectEqual(@as(f32, 10), quads[1].width);
    try testing.expect(quads[0].top[0] > 0.78 and quads[0].top[0] < 0.79); // 200/255 red
}

test "a layer a higher opaque layer fully covers is not encoded" {
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
        .{ .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const lower = solidList(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const upper = solidList(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ .r = 0, .g = 200, .b = 0, .a = 255 });
    const lists = [_]DisplayList{ &lower, &upper };

    var layer_buf: [8]Layer = undefined;
    const quads = try encode(testing.allocator, tree, &lists, &layer_buf, .screen);
    defer testing.allocator.free(quads);

    // Only the upper (green) survived; the covered red is never encoded.
    try testing.expectEqual(@as(usize, 1), quads.len);
    try testing.expect(quads[0].top[1] > 0.78); // green
    try testing.expect(quads[0].top[0] < 0.01); // no red
}

test "a layer's opacity is folded into its quads' alpha" {
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .opacity = 0.5 },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const list = solidList(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const lists = [_]DisplayList{&list};

    var layer_buf: [8]Layer = undefined;
    const quads = try encode(testing.allocator, tree, &lists, &layer_buf, .screen);
    defer testing.allocator.free(quads);

    try testing.expectEqual(@as(usize, 1), quads.len);
    try testing.expect(quads[0].top[3] > 0.49 and quads[0].top[3] < 0.51); // a=1.0 * 0.5
}

test "each of the four commands maps to the right quad shape" {
    var nodes = [_]Node{.{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } }};
    const tree: Tree = .{ .nodes = &nodes };
    const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const rect = paint.Rect{ .x = 0, .y = 0, .w = 50, .h = 50 };
    const list = [_]paint.Command{
        .{ .solid = .{ .rect = rect, .colour = white } },
        .{ .vgradient = .{ .rect = rect, .top = white, .bottom = black } },
        .{ .rounded = .{ .rect = rect, .radius = 8, .colour = white } },
        .{ .rounded_vgradient = .{ .rect = rect, .radius = 8, .top = white, .bottom = black } },
    };
    const lists = [_]DisplayList{&list};

    var layer_buf: [8]Layer = undefined;
    const quads = try encode(testing.allocator, tree, &lists, &layer_buf, .screen);
    defer testing.allocator.free(quads);

    try testing.expectEqual(@as(usize, 4), quads.len);
    // solid: sharp, one colour.
    try testing.expectEqual(@as(f32, 0), quads[0].radius);
    try testing.expectEqualSlices(f32, &quads[0].top, &quads[0].bottom);
    // vgradient: sharp, two colours.
    try testing.expectEqual(@as(f32, 0), quads[1].radius);
    try testing.expect(quads[1].top[0] > quads[1].bottom[0]);
    // rounded: a radius, one colour.
    try testing.expectEqual(@as(f32, 8), quads[2].radius);
    try testing.expectEqualSlices(f32, &quads[2].top, &quads[2].bottom);
    // rounded_vgradient: a radius, two colours.
    try testing.expectEqual(@as(f32, 8), quads[3].radius);
    try testing.expect(quads[3].top[0] > quads[3].bottom[0]);
}

test "the clip carried on a quad is the layer's clipped world bounds" {
    // A clipping parent 10 wide; a child that draws 20 wide.
    var nodes = [_]Node{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .clip = true },
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 10 } },
    };
    const tree: Tree = .{ .nodes = &nodes };
    const empty = [_]paint.Command{};
    const child = solidList(.{ .x = 0, .y = 0, .w = 20, .h = 10 }, .{ .r = 0, .g = 0, .b = 200, .a = 255 });
    const lists = [_]DisplayList{ &empty, &child };

    var layer_buf: [8]Layer = undefined;
    const quads = try encode(testing.allocator, tree, &lists, &layer_buf, .screen);
    defer testing.allocator.free(quads);

    try testing.expectEqual(@as(usize, 1), quads.len); // only the child draws
    // The quad is authored 20 wide, but its clip is confined to the 10-wide parent, so the device
    // scissors away the overflow the software path clips.
    try testing.expectEqual(@as(f32, 20), quads[0].width);
    try testing.expect(quads[0].clip.width <= 10);
}
