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
pub const boot_scenario = @import("scenarios/boot.zig");
pub const rollback_scenario = @import("scenarios/rollback.zig");

// Deterministic core: the virtual clock, task scheduling order, and fault timing that make every
// run reproducible.
pub const clock = @import("clock/virtual.zig");
pub const scheduler = @import("scheduler/ordering.zig");
pub const failure = @import("failure/injection.zig");

test {
    _ = host;
    _ = model;
    _ = canonical;
    _ = boot_scenario;
    _ = rollback_scenario;
    _ = clock;
    _ = scheduler;
    _ = failure;
}
