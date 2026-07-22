//! Design system: semantic tokens and the accessibility contract.
//!
//! Surfaces consume roles rather than values, so a brand change cannot alter
//! what a colour means. Accessibility is expressed as structure a test can
//! check rather than as a review someone performs on a finished layout.
//!
//! This module holds assets and rules. It contains no product logic.

pub const tokens = @import("tokens/tokens.zig");
pub const accessibility = @import("accessibility/accessibility.zig");

test {
    _ = tokens;
    _ = accessibility;
}
