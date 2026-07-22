//! The session shell.
//!
//! Surfaces project control-plane state rather than holding their own copy of
//! it, so what the user sees is what the system can account for. The command
//! surface stays reachable, agent activity stays visible, and no surface can
//! present an action as complete before it is.

pub const surfaces = @import("surfaces/surfaces.zig");

test {
    _ = surfaces;
}
