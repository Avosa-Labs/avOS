//! The session shell.
//!
//! Surfaces project control-plane state rather than holding their own copy of
//! it, so what the user sees is what the system can account for. The command
//! surface stays reachable, agent activity stays visible, and no surface can
//! present an action as complete before it is.

pub const surfaces = @import("surfaces/surfaces.zig");
pub const command = @import("command/command.zig");
pub const inspectors = @import("inspectors/inspectors.zig");
pub const session = @import("session/session.zig");
pub const render = @import("render/render.zig");

test {
    _ = surfaces;
    _ = command;
    _ = inspectors;
    _ = session;
    _ = render;
}
