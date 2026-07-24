//! What a release is made of.
//!
//! The formats here describe artifacts rather than behavior: what an image
//! contains, what a device is told about it, and what a signature covers. They
//! are separate from the code that installs them so that a device and a build
//! host agree on the format without sharing anything else.

pub const image = @import("images/image.zig");
pub const manifest = @import("manifests/manifest.zig");
pub const rollout = @import("policies/rollout.zig");
pub const recovery = @import("recovery/fallback.zig");
pub const channel = @import("release/channel.zig");
pub const emulator_bundle = @import("emulator/bundle.zig");

test {
    _ = image;
    _ = manifest;
    _ = rollout;
    _ = recovery;
    _ = channel;
    _ = emulator_bundle;
}
