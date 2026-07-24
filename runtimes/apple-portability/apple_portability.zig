//! Apple-platform source portability.
//!
//! Bringing an app's source from an Apple platform to this one is only worth doing if it
//! is honest about what carries over. These modules classify that honestly rather than
//! papering over gaps: an API is portable, host-mapped to a named equivalent, or
//! reported unsupported; a required system interface the host lacks fails the port at
//! build time rather than crashing in the field; and a declarative-UI element with no
//! host component is reported rather than silently dropped from the screen. Each decides
//! rather than transforms, so a developer sees the real cost of the move up front.

pub const portability = @import("source-portability/portability.zig");
pub const interfaces = @import("interfaces/interfaces.zig");
pub const declarative_ui = @import("declarative-ui/declarative_ui.zig");

test {
    _ = portability;
    _ = interfaces;
    _ = declarative_ui;
}
