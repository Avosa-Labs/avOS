//! Domain model for the trusted control plane.
//!
//! This module depends only on the standard library. It holds no service
//! implementation, no transport, no interface code, and no model or provider
//! vocabulary: it defines what a principal, a capability, a task, a budget, and
//! an audit record are, and the rules that govern them.
//!
//! Services compose these types. Nothing here reaches back into a service.

pub const outcome = @import("base/outcome.zig");
pub const identity = @import("identity/identity.zig");
pub const time = @import("time/time.zig");
pub const resource = @import("resource/resource.zig");
pub const principal = @import("principal/principal.zig");
pub const capability = @import("capability/capability.zig");
pub const task = @import("task/task.zig");
pub const audit = @import("audit/audit.zig");
pub const policy = @import("policy/policy.zig");
pub const package = @import("package/package.zig");

test {
    _ = outcome;
    _ = identity;
    _ = time;
    _ = resource;
    _ = principal;
    _ = capability;
    _ = task;
    _ = audit;
    _ = policy;
    _ = package;
}
