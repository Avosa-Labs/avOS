//! Deterministic host for the control plane.
//!
//! The simulator runs the principal, capability, task, resource, audit, and
//! policy models on a development machine with no device, no compatibility
//! runtime, and no network. It is the first implementation target: correctness
//! is established here, where a run is reproducible and a failure is
//! observable, before anything reaches hardware.

pub const host = @import("host/host.zig");
pub const model = @import("model/model.zig");
pub const canonical = @import("scenarios/canonical.zig");

test {
    _ = host;
    _ = model;
    _ = canonical;
}
