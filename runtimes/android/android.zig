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

test {
    _ = permissions;
}
