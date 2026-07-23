//! Domain model for the trusted control plane.
//!
//! This module depends only on the standard library. It holds no service
//! implementation, no transport, no interface code, and no model or provider
//! vocabulary: it defines what a principal, a capability, a task, a budget, and
//! an audit record are, and the rules that govern them.
//!
//! Services compose these types. Nothing here reaches back into a service.

pub const outcome = @import("base/outcome.zig");
pub const collections = @import("collections/collections.zig");
pub const diagnostics = @import("diagnostics/diagnostics.zig");
pub const encoding = @import("encoding/encoding.zig");
pub const localization = @import("localization/localization.zig");
pub const identity = @import("identity/identity.zig");
pub const time = @import("time/time.zig");
pub const resource = @import("resource/resource.zig");
pub const principal = @import("principal/principal.zig");
pub const capability = @import("capability/capability.zig");
pub const task = @import("task/task.zig");
pub const audit = @import("audit/audit.zig");
pub const policy = @import("policy/policy.zig");
pub const provenance = @import("provenance/provenance.zig");
pub const package = @import("package/package.zig");
pub const update = @import("update/update.zig");

test {
    _ = outcome;
    _ = collections;
    _ = diagnostics;
    _ = encoding;
    _ = localization;
    _ = identity;
    _ = time;
    _ = resource;
    _ = principal;
    _ = capability;
    _ = task;
    _ = audit;
    _ = policy;
    _ = provenance;
    _ = package;
    _ = update;
}
