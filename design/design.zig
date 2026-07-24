//! Design system: semantic tokens and the accessibility contract.
//!
//! Surfaces consume roles rather than values, so a brand change cannot alter
//! what a colour means. Accessibility is expressed as structure a test can
//! check rather than as a review someone performs on a finished layout.
//!
//! This module holds assets and rules. It contains no product logic.

pub const tokens = @import("tokens/tokens.zig");
pub const accessibility = @import("accessibility/accessibility.zig");
pub const contrast = @import("color/contrast.zig");
pub const typography = @import("typography/typography.zig");
pub const motion = @import("motion/motion.zig");
pub const sound = @import("sound/sound.zig");
pub const haptics = @import("haptics/haptics.zig");
pub const components = @import("components/components.zig");
pub const layouts = @import("layouts/layouts.zig");
pub const icons = @import("icons/icons.zig");
pub const materials = @import("materials/materials.zig");

test {
    _ = tokens;
    _ = accessibility;
    _ = contrast;
    _ = typography;
    _ = motion;
    _ = sound;
    _ = haptics;
    _ = components;
    _ = layouts;
    _ = icons;
    _ = materials;
}
