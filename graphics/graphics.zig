//! The graphics layer.
//!
//! Everything drawn on screen passes through here, and the modules decide rather than
//! rasterize: what is visible and worth drawing, what fits a frame's budget, what a colour
//! or material may be, and — the properties that make the layer safe — that a secure
//! surface is never read back and a decompression bomb is never decoded. The GPU is driven
//! below this decision layer; what lives here is the policy that keeps rendering correct,
//! bounded, and private, testable without a GPU.

pub const color = @import("color/color.zig");
pub const linear = @import("color/linear.zig");
pub const compositor = @import("compositor/compositor.zig");
pub const surfaces = @import("surfaces/surfaces.zig");
pub const renderer = @import("renderer/renderer.zig");
pub const scene = @import("scene/scene.zig");
pub const scene_tree = @import("scene/tree.zig");
pub const scene_damage = @import("scene/damage.zig");
pub const scene_hittest = @import("scene/hittest.zig");
pub const compositor_layers = @import("compositor/layers.zig");
pub const accessibility_frame = @import("accessibility/frame.zig");
pub const animation = @import("animation/animation.zig");
pub const interpolate = @import("animation/interpolate.zig");
pub const effects = @import("effects/effects.zig");
pub const materials = @import("materials/materials.zig");
pub const linebreak = @import("text/linebreak.zig");
pub const shaping = @import("text/shaping.zig");
pub const text_layout = @import("text/layout.zig");
pub const device = @import("device/device.zig");
pub const image_decode = @import("images/decode.zig");
pub const video_pacing = @import("video/pacing.zig");
pub const privacy = @import("privacy/privacy.zig");
pub const capture = @import("capture/capture.zig");

// The concrete render layer: the framebuffer the pipeline draws onto, and the painter that executes a
// display list into pixels. Where the modules above decide, these produce.
pub const framebuffer = @import("paint/framebuffer.zig");
pub const paint = @import("paint/paint.zig");
pub const vector = @import("paint/vector.zig");
pub const iconography = @import("paint/iconography.zig");
pub const text = @import("paint/text.zig");
pub const phone = @import("paint/phone.zig");
pub const home = @import("paint/home.zig");
pub const screens = @import("paint/screens.zig");
pub const apps = @import("paint/apps.zig");
// The GPU backend: the same display list encoded to an instance buffer a GPU draws in one pass, and
// pointer hit-testing that routes a tap to the topmost target for the input decision layer.
pub const backend = @import("paint/backend.zig");
pub const pointer = @import("paint/pointer.zig");
pub const anim = @import("paint/anim.zig");
pub const motion = @import("paint/motion.zig");

test {
    _ = color;
    _ = linear;
    _ = compositor;
    _ = surfaces;
    _ = renderer;
    _ = scene;
    _ = scene_tree;
    _ = scene_damage;
    _ = scene_hittest;
    _ = compositor_layers;
    _ = accessibility_frame;
    _ = animation;
    _ = interpolate;
    _ = effects;
    _ = materials;
    _ = linebreak;
    _ = shaping;
    _ = text_layout;
    _ = device;
    _ = image_decode;
    _ = video_pacing;
    _ = privacy;
    _ = capture;
    _ = framebuffer;
    _ = paint;
    _ = vector;
    _ = iconography;
    _ = text;
    _ = home;
    _ = screens;
    _ = apps;
    _ = backend;
    _ = pointer;
    _ = anim;
    _ = motion;
}
