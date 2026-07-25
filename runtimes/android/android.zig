//! Android compatibility runtime.
//!
//! Android applications run inside a distinct isolation boundary with their own
//! application identity, separate from any host principal. Their permissions
//! are statements inside the Android framework's authority model and mean
//! nothing here until translated into host capability requests, which the host
//! then decides on.
//!
//! Framework privilege never becomes host privilege. A dependency this host
//! cannot satisfy is reported rather than stubbed.

pub const permissions = @import("permissions/permissions.zig");
pub const bridge = @import("bridge/bridge.zig");
pub const image = @import("image/image.zig");
pub const lifecycle = @import("lifecycle/lifecycle.zig");
pub const capabilities = @import("capabilities/capabilities.zig");
pub const compatibility = @import("compatibility/compatibility.zig");
pub const storage = @import("storage/storage.zig");
pub const notifications = @import("notifications/notifications.zig");

test {
    _ = permissions;
    _ = bridge;
    _ = image;
    _ = lifecycle;
    _ = capabilities;
    _ = compatibility;
    _ = storage;
    _ = notifications;
}
