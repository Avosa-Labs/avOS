//! The one path from a scene to a presented frame: flatten, submit, present.
//!
//! A surface never draws to the screen itself. It contributes nodes to the retained tree, and
//! the compositor is the single thing that turns that tree into a frame and puts it on a
//! device. This is that path: flatten the tree into its visible, culled layers, submit them to
//! the device seam, and present. Whichever device is behind the seam — the GPU adapter or the
//! software rasterizer — is a deployment choice made elsewhere; here there is exactly one way
//! a frame reaches a display, so "the compositor alone presents" is a property of the code and
//! not a convention to remember.
//!
//! The damage-gated variant keeps the zero-idle-GPU discipline at the frame path: a frame with
//! nothing changed submits nothing, so an idle interface costs no GPU work.

const std = @import("std");
const tree_mod = @import("../scene/tree.zig");
const layers = @import("layers.zig");
const damage = @import("../scene/damage.zig");
const dev = @import("../device/device.zig");

/// Composites and presents one frame: flattens the tree to its visible layers for `target`
/// and drives the device seam. The only path a frame reaches a display.
pub fn present(tree: tree_mod.Tree, device: dev.Device, target: layers.Target, layer_buffer: []layers.Layer) dev.Error!void {
    const flat = layers.flattenForTarget(tree, layer_buffer, target);
    try device.submit(.{ .layers = flat, .target = target });
    try device.present();
}

/// Presents only when the frame changed. With clean damage nothing is flattened, submitted, or
/// presented — the idle case costs nothing. Returns whether a frame was presented.
pub fn presentIfDamaged(
    tree: tree_mod.Tree,
    device: dev.Device,
    target: layers.Target,
    layer_buffer: []layers.Layer,
    set: damage.DamageSet,
) dev.Error!bool {
    if (set.isClean()) return false;
    try present(tree, device, target, layer_buffer);
    return true;
}

// --- Tests ---

const testing = std.testing;
const SoftwareDevice = dev.SoftwareDevice;
const Node = tree_mod.Node;

fn twoNodeTree() [2]Node {
    return .{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
        .{ .parent = 0, .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
}

test "presenting flattens the visible layers and drives the device once" {
    var nodes = twoNodeTree();
    const tree: tree_mod.Tree = .{ .nodes = &nodes };

    var software = SoftwareDevice.init();
    var buffer: [8]layers.Layer = undefined;
    try present(tree, software.device(), .screen, &buffer);

    try testing.expectEqual(@as(usize, 2), software.last_frame_layers); // both nodes visible
    try testing.expectEqual(layers.Target.screen, software.last_target.?);
    try testing.expectEqual(@as(u64, 1), software.presented);
}

test "a clean frame presents nothing; a damaged one presents" {
    var nodes = twoNodeTree();
    const tree: tree_mod.Tree = .{ .nodes = &nodes };
    var software = SoftwareDevice.init();
    var buffer: [8]layers.Layer = undefined;

    var clean_storage: [4]damage.Rect = undefined;
    const clean: damage.DamageSet = .init(&clean_storage);
    try testing.expectEqual(false, try presentIfDamaged(tree, software.device(), .screen, &buffer, clean));
    try testing.expectEqual(@as(u64, 0), software.presented); // idle: nothing presented

    var dirty_storage: [4]damage.Rect = undefined;
    var dirty: damage.DamageSet = .init(&dirty_storage);
    dirty.add(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try testing.expectEqual(true, try presentIfDamaged(tree, software.device(), .screen, &buffer, dirty));
    try testing.expectEqual(@as(u64, 1), software.presented);
}

test "the capture target flattens for capture, withholding nothing here" {
    var nodes = twoNodeTree();
    const tree: tree_mod.Tree = .{ .nodes = &nodes };
    var software = SoftwareDevice.init();
    var buffer: [8]layers.Layer = undefined;
    try present(tree, software.device(), .capture, &buffer);
    try testing.expectEqual(layers.Target.capture, software.last_target.?);
}
