//! The agent execution plane.
//!
//! Agents are first-class principals, not hidden application features, and the
//! modules here are what keep an agent's autonomy safe: what a model's output is
//! allowed to become, and how a consequential action is held for a person. They
//! decide rather than execute, composing the provenance, capability, and task
//! models the control plane already provides, so the safety properties are the
//! same whether an agent runs on device or reaches for a remote model.

pub const approvals = @import("approvals/approvals.zig");
pub const injection_defense = @import("injection-defense/injection_defense.zig");

test {
    _ = approvals;
    _ = injection_defense;
}
