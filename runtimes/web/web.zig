//! Web content runtime.
//!
//! Web content — pages, scripts, and everything they fetch — is untrusted, so the web
//! runtime is a boundary before it is a renderer. It isolates origins from each other by
//! the same-origin policy, translates a page's permission asks into host capability
//! requests the host decides, exposes host authority only through a small named bridge
//! whose consequential crossings need approval, admits downloads only within quota and
//! never runs them on arrival, and refuses navigation that would reach a privileged
//! surface or downgrade a secure session. Each module decides rather than executes, so
//! the safety properties are the same however a page is rendered.

pub const origins = @import("origins/origins.zig");
pub const permissions = @import("permissions/permissions.zig");
pub const bridge = @import("bridge/bridge.zig");
pub const downloads = @import("downloads/downloads.zig");
pub const navigation = @import("engine/navigation.zig");

test {
    _ = origins;
    _ = permissions;
    _ = bridge;
    _ = downloads;
    _ = navigation;
}
