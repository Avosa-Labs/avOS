//! Trusted control-plane services.
//!
//! Services run as separate processes and talk over the inter-service
//! protocol. Separation is the point: a service that faults takes its own
//! address space with it and nothing else, which is what makes a service
//! boundary a trust boundary rather than a naming convention.

pub const background_work = @import("background-work/background_work.zig");
pub const notification = @import("notification/notification.zig");
pub const supervisor = @import("supervisor/supervisor.zig");
pub const restart_policy = @import("supervisor/policy.zig");
pub const policy = @import("policy/policy.zig");
pub const secret = @import("secret/secret.zig");
pub const update_rollout = @import("update/rollout.zig");
pub const power = @import("power/power.zig");
pub const emergency = @import("emergency/emergency.zig");
pub const clipboard = @import("clipboard/clipboard.zig");
pub const location = @import("location/location.zig");
pub const sensor = @import("sensor/sensor.zig");
pub const diagnostics = @import("diagnostics/diagnostics.zig");
pub const account = @import("account/account.zig");
pub const connectivity = @import("connectivity/connectivity.zig");
pub const device_posture = @import("device/posture.zig");
pub const session_lock = @import("session/lock.zig");
pub const application_install = @import("application/install.zig");
pub const search = @import("search/search.zig");
pub const window_overlay = @import("window/overlay.zig");

test {
    _ = background_work;
    _ = notification;
    _ = supervisor;
    _ = restart_policy;
    _ = policy;
    _ = secret;
    _ = update_rollout;
    _ = power;
    _ = emergency;
    _ = clipboard;
    _ = location;
    _ = sensor;
    _ = diagnostics;
    _ = account;
    _ = connectivity;
    _ = device_posture;
    _ = session_lock;
    _ = application_install;
    _ = search;
    _ = window_overlay;
}
