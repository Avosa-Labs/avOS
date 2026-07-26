//! The brand mark, as decoded pixels ready to blit.
//!
//! The logo is authored as an image. Rather than ship a PNG decoder on the boot path, the
//! artwork is decoded once at build time to raw 8-bit RGBA and embedded here, so the boot
//! screen blits the real mark directly — the actual logo, alpha and all, not an
//! approximation of it. Square, premultiplied by nothing; the transparent corners carry
//! the circle's shape in the alpha channel.

/// The mark as raw RGBA, row-major, `size` x `size`.
pub const rgba: []const u8 = @embedFile("logo256.rgba");

/// The mark's edge length in pixels.
pub const size: u32 = 256;
