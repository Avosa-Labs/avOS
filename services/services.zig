//! Trusted control-plane services.
//!
//! Services run as separate processes and talk over the inter-service
//! protocol. Separation is the point: a service that faults takes its own
//! address space with it and nothing else, which is what makes a service
//! boundary a trust boundary rather than a naming convention.

pub const supervisor = @import("supervisor/supervisor.zig");
pub const restart_policy = @import("supervisor/policy.zig");

test {
    _ = supervisor;
    _ = restart_policy;
}
