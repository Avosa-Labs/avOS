//! WebAssembly component runtime.
//!
//! Guest code runs with no ambient authority: no import is supplied, so a
//! module that declares one is refused rather than stubbed. Execution is
//! metered by fuel and bounded by an epoch deadline the guest cannot decline,
//! memory is capped per instance, and a fault is contained.

pub const engine = @import("host/engine.zig");
pub const component = @import("host/component.zig");
pub const vectors = @import("host/vectors.zig");

test {
    _ = engine;
    _ = component;
    _ = vectors;
}
