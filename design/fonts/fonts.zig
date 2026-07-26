//! The interface's typeface, embedded so it compiles into the binary and needs no file
//! at runtime.
//!
//! The design's typeface is Sora, under the SIL Open Font License (the licence travels
//! beside the outlines in `OFL.txt`). The bytes are exposed here as design assets; the
//! graphics text stack reads them and rasterizes the glyphs. Kept in the design layer
//! because the typeface is part of the design, not the renderer.

/// Sora Regular — body text.
pub const sora_regular = @embedFile("Sora-Regular.ttf");

/// Sora SemiBold — headings and emphasis.
pub const sora_semibold = @embedFile("Sora-SemiBold.ttf");
