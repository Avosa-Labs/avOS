//! The one path from a scene to a presented frame: submit the scene, present.
//!
//! A surface never draws to the screen itself. It contributes nodes to the retained tree, and
//! the compositor is the single thing that turns that tree into a frame and puts it on a
//! device. This is that path: hand the retained scene — the tree and its per-node display lists
//! — to the device seam, and present. The device flattens, culls, and draws the scene its own
//! way; whichever device is behind the seam — the GPU adapter or the software rasterizer — is a
//! deployment choice made elsewhere, so here there is exactly one way a frame reaches a display
//! and "the compositor alone presents" is a property of the code, not a convention to remember.
//!
//! The damage-gated variant keeps the zero-idle-GPU discipline at the frame path: a frame with
//! nothing changed submits nothing, so an idle interface costs no GPU work.

const std = @import("std");
const tree_mod = @import("../scene/tree.zig");
const layers = @import("layers.zig");
const damage = @import("../scene/damage.zig");
const dev = @import("../device/device.zig");

/// Composites and presents one frame: hands the retained scene — the tree and its per-node
/// display lists — to the device seam for `target`, then presents. The device owns its flatten
/// buffer and draws the scene its own way. The only path a frame reaches a display.
pub fn present(tree: tree_mod.Tree, lists: []const dev.DisplayList, device: dev.Device, target: layers.Target) dev.Error!void {
    try device.submit(.{ .tree = tree, .lists = lists, .target = target });
    try device.present();
}

/// Presents only when the frame changed. With clean damage nothing is submitted or presented —
/// the idle case costs nothing. Returns whether a frame was presented.
pub fn presentIfDamaged(
    tree: tree_mod.Tree,
    lists: []const dev.DisplayList,
    device: dev.Device,
    target: layers.Target,
    set: damage.DamageSet,
) dev.Error!bool {
    if (set.isClean()) return false;
    try present(tree, lists, device, target);
    return true;
}

// --- Tests ---

const testing = std.testing;
const SoftwareDevice = dev.SoftwareDevice;
const Node = tree_mod.Node;
const paint = @import("../paint/paint.zig");

fn twoNodeTree() [2]Node {
    return .{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
}

fn solidList(rect: paint.Rect, colour: dev.Rgba) [1]paint.Command {
    return .{.{ .solid = .{ .rect = rect, .colour = colour } }};
}

fn fixture(buffer: []layers.Layer) SoftwareDevice {
    return SoftwareDevice.init(testing.allocator, 40, 40, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, buffer);
}

test "presenting composites the scene and drives the device once" {
    var nodes = twoNodeTree();
    const tree: tree_mod.Tree = .{ .nodes = &nodes };
    const bg = solidList(.{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const fg = solidList(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 0, .g = 0, .b = 200, .a = 255 });
    const lists = [_]dev.DisplayList{ &bg, &fg };

    var buffer: [8]layers.Layer = undefined;
    var software = fixture(&buffer);
    defer software.deinit();
    try present(tree, &lists, software.device(), .screen);

    try testing.expectEqual(layers.Target.screen, software.last_target.?);
    try testing.expectEqual(@as(u8, 200), software.image.?.get(5, 5).r); // background composited
    try testing.expectEqual(@as(u64, 1), software.presented);
}

test "a clean frame presents nothing; a damaged one presents" {
    var nodes = twoNodeTree();
    const tree: tree_mod.Tree = .{ .nodes = &nodes };
    const bg = solidList(.{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const empty = [_]paint.Command{};
    const lists = [_]dev.DisplayList{ &bg, &empty };

    var buffer: [8]layers.Layer = undefined;
    var software = fixture(&buffer);
    defer software.deinit();

    var clean_storage: [4]damage.Rect = undefined;
    const clean: damage.DamageSet = .init(&clean_storage);
    try testing.expectEqual(false, try presentIfDamaged(tree, &lists, software.device(), .screen, clean));
    try testing.expectEqual(@as(u64, 0), software.presented); // idle: nothing presented

    var dirty_storage: [4]damage.Rect = undefined;
    var dirty: damage.DamageSet = .init(&dirty_storage);
    dirty.add(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try testing.expectEqual(true, try presentIfDamaged(tree, &lists, software.device(), .screen, dirty));
    try testing.expectEqual(@as(u64, 1), software.presented);
}

test "the capture target composites for capture, withholding nothing here" {
    var nodes = twoNodeTree();
    const tree: tree_mod.Tree = .{ .nodes = &nodes };
    const bg = solidList(.{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ .r = 200, .g = 0, .b = 0, .a = 255 });
    const empty = [_]paint.Command{};
    const lists = [_]dev.DisplayList{ &bg, &empty };

    var buffer: [8]layers.Layer = undefined;
    var software = fixture(&buffer);
    defer software.deinit();
    try present(tree, &lists, software.device(), .capture);
    try testing.expectEqual(layers.Target.capture, software.last_target.?);
}
