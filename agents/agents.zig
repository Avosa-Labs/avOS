//! The agent execution plane.
//!
//! Agents are first-class principals, not hidden application features, and the
//! modules here are what keep an agent's autonomy safe: what a model's output is
//! allowed to become, and how a consequential action is held for a person. They
//! decide rather than execute, composing the provenance, capability, and task
//! models the control plane already provides, so the safety properties are the
//! same whether an agent runs on device or reaches for a remote model.

pub const approvals = @import("approvals/approvals.zig");
pub const context = @import("context/context.zig");
pub const device_control = @import("device-control/device_control.zig");
pub const injection_defense = @import("injection-defense/injection_defense.zig");
pub const planner = @import("planner/planner.zig");
pub const router = @import("router/router.zig");
pub const scheduler = @import("scheduler/scheduler.zig");
pub const tool_registry = @import("tool-registry/tool_registry.zig");
pub const host = @import("host/host.zig");
pub const lifecycle = @import("lifecycle/lifecycle.zig");
pub const graph_compiler = @import("graph-compiler/compiler.zig");
pub const policy = @import("policy/policy.zig");
pub const provenance = @import("provenance/propagation.zig");
pub const memory = @import("memory/memory.zig");
pub const retrieval = @import("retrieval/retrieval.zig");
pub const knowledge = @import("knowledge/knowledge.zig");
pub const model_interface = @import("model/interface/interface.zig");
pub const model_local = @import("model/local/local.zig");
pub const model_remote = @import("model/remote/remote.zig");

test {
    _ = approvals;
    _ = context;
    _ = device_control;
    _ = injection_defense;
    _ = planner;
    _ = router;
    _ = scheduler;
    _ = tool_registry;
    _ = host;
    _ = lifecycle;
    _ = graph_compiler;
    _ = policy;
    _ = provenance;
    _ = memory;
    _ = retrieval;
    _ = knowledge;
    _ = model_interface;
    _ = model_local;
    _ = model_remote;
}
