//! The graphics layer.
//!
//! Everything drawn on screen passes through here, and the modules decide rather than
//! rasterize: what is visible and worth drawing, what fits a frame's budget, what a colour
//! or material may be, and — the properties that make the layer safe — that a secure
//! surface is never read back and a decompression bomb is never decoded. The GPU is driven
//! below this decision layer; what lives here is the policy that keeps rendering correct,
//! bounded, and private, testable without a GPU.

pub const color = @import("color/color.zig");
pub const compositor = @import("compositor/compositor.zig");
pub const surfaces = @import("surfaces/surfaces.zig");
pub const renderer = @import("renderer/renderer.zig");
pub const scene = @import("scene/scene.zig");
pub const animation = @import("animation/animation.zig");
pub const effects = @import("effects/effects.zig");
pub const materials = @import("materials/materials.zig");
pub const linebreak = @import("text/linebreak.zig");
pub const image_decode = @import("images/decode.zig");
pub const video_pacing = @import("video/pacing.zig");
pub const privacy = @import("privacy/privacy.zig");
pub const capture = @import("capture/capture.zig");

test {
    _ = color;
    _ = compositor;
    _ = surfaces;
    _ = renderer;
    _ = scene;
    _ = animation;
    _ = effects;
    _ = materials;
    _ = linebreak;
    _ = image_decode;
    _ = video_pacing;
    _ = privacy;
    _ = capture;
}
