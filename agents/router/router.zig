//! Choosing which model answers a request, keeping what can stay on the device
//! on the device.
//!
//! An agent request can be served by a small local model, a large local model,
//! or a remote one, and the choice is not only about capability. Sending a
//! request to a remote model sends its contents off the device, which for
//! anything touching a person's private data is a disclosure that must be
//! justified, not a default. So routing has a rule beneath the capability match:
//! a request that a local model can serve is served locally, and a request only
//! a remote model can serve leaves the device only when its data is cleared to,
//! and never silently.
//!
//! This module makes that choice. It runs no model; it picks which backend a
//! request should go to, or refuses when the only capable backend is one the
//! request's data may not reach. The rule composes the provenance model — data
//! that must stay on the device cannot be routed off it — so the privacy
//! property is enforced at the routing boundary rather than hoped for at each
//! call site.

const std = @import("std");
const core = @import("core");

/// Where a model runs.
///
/// Ordered by how much leaves the device: a local model discloses nothing, a
/// remote one discloses the whole request. The order lets routing prefer the
/// least-disclosing capable backend.
pub const Backend = enum(u8) {
    /// A small on-device model: fast, private, limited.
    local_small = 0,
    /// A large on-device model: slower, private, more capable.
    local_large = 1,
    /// A remote model: most capable, but the request leaves the device.
    remote = 2,

    /// Whether using this backend sends the request off the device.
    pub fn leavesDevice(backend: Backend) bool {
        return backend == .remote;
    }
};

/// How much capability a request needs.
///
/// Ordered, so a backend "can serve" a request when its own capability is at
/// least the request's need.
pub const Capability = enum(u8) {
    /// Classification, short completion, simple extraction. Any backend serves
    /// it.
    light = 0,
    /// Summarization, structured generation, multi-step reasoning. Needs a large
    /// model.
    heavy = 1,
    /// Frontier reasoning a local model cannot do. Only remote serves it.
    frontier = 2,

    fn servedBy(need: Capability, backend: Backend) bool {
        const backend_capability: Capability = switch (backend) {
            .local_small => .light,
            .local_large => .heavy,
            .remote => .frontier,
        };
        return @intFromEnum(backend_capability) >= @intFromEnum(need);
    }
};

/// A request to be routed.
pub const Request = struct {
    /// How capable a model the request needs.
    need: Capability,
    /// The provenance of the request's data, which decides whether it may leave
    /// the device.
    provenance: core.provenance.Provenance,
};

/// Why a request could not be routed.
pub const Refusal = enum {
    /// The request needs a capability only remote provides, but its data may not
    /// leave the device. The privacy floor wins over the capability need.
    would_leave_device,
};

/// The routing outcome.
pub const Decision = union(enum) {
    route: Backend,
    hold: Refusal,

    pub fn routed(decision: Decision) bool {
        return decision == .route;
    }
};

/// Whether a request's data may be sent to a remote model.
///
/// Only if its provenance clears it for an external action. Data trusted at its
/// source, or explicitly validated as safe to send, may leave; anything else
/// stays, because routing a person's private context to a remote model is
/// exactly the disclosure that must be deliberate.
fn mayLeaveDevice(provenance: core.provenance.Provenance) bool {
    return provenance.permits(.external_action);
}

/// Chooses a backend for a request.
///
/// Picks the least-disclosing backend that can serve the request: a light
/// request goes to the small local model, a heavy one to the large local model,
/// and only a frontier request reaches for remote. A request that needs remote
/// is routed there only if its data is cleared to leave the device; otherwise it
/// is held rather than silently disclosed, so the privacy floor is never crossed
/// to satisfy a capability need.
pub fn route(request: Request) Decision {
    // Try each backend from least- to most-disclosing; take the first that can
    // serve the request.
    for ([_]Backend{ .local_small, .local_large, .remote }) |backend| {
        if (!request.need.servedBy(backend)) continue;
        if (backend.leavesDevice() and !mayLeaveDevice(request.provenance)) {
            // The only capable backend is remote, but the data may not leave.
            // The privacy floor wins.
            return .{ .hold = .would_leave_device };
        }
        return .{ .route = backend };
    }
    unreachable; // remote serves every capability, so a backend is always found
}

fn requestOf(need: Capability, origin: core.provenance.Origin) Request {
    return .{ .need = need, .provenance = core.provenance.Provenance.from(origin) };
}

test "a light request goes to the small local model" {
    // The least-disclosing capable backend, and it discloses nothing.
    const decision = route(requestOf(.light, .human_input));
    try std.testing.expectEqual(Decision{ .route = .local_small }, decision);
}

test "a heavy request goes to the large local model" {
    const decision = route(requestOf(.heavy, .human_input));
    try std.testing.expectEqual(Decision{ .route = .local_large }, decision);
    // And it stays on the device.
    try std.testing.expect(!decision.route.leavesDevice());
}

test "a frontier request with clearable data goes remote" {
    // Human input is trusted, so it may leave the device for a frontier request.
    const decision = route(requestOf(.frontier, .human_input));
    try std.testing.expectEqual(Decision{ .route = .remote }, decision);
}

test "a frontier request with private data is held, not disclosed" {
    // Model output that was never cleared to leave the device: the frontier need
    // does not override the privacy floor.
    const decision = route(requestOf(.frontier, .model_output));
    try std.testing.expectEqual(Decision{ .hold = .would_leave_device }, decision);
}

test "explicitly cleared data may go remote even from an untrusted origin" {
    // Model output validated as safe to send externally may leave.
    const cleared = core.provenance.validate(
        core.provenance.Provenance.from(.model_output),
        .external_action,
        true,
    ).?.result;
    const decision = route(.{ .need = .frontier, .provenance = cleared });
    try std.testing.expectEqual(Decision{ .route = .remote }, decision);
}

test "a light request from private data still stays local without leaving" {
    // It never needed remote, so the privacy question does not even arise.
    const decision = route(requestOf(.light, .external_input));
    try std.testing.expect(decision.routed());
    try std.testing.expect(!decision.route.leavesDevice());
}

test "a local-serviceable request never leaves the device whatever its data" {
    // Swept: every light and heavy request routes to a local backend regardless
    // of origin, because a local model can serve it and discloses nothing.
    for (std.enums.values(core.provenance.Origin)) |origin| {
        for ([_]Capability{ .light, .heavy }) |need| {
            const decision = route(requestOf(need, origin));
            try std.testing.expect(decision.routed());
            try std.testing.expect(!decision.route.leavesDevice());
        }
    }
}

test "a frontier request leaves the device only when its data is cleared" {
    // Swept: the disclosure happens for exactly the origins cleared to leave.
    for (std.enums.values(core.provenance.Origin)) |origin| {
        const request = requestOf(.frontier, origin);
        const decision = route(request);
        if (mayLeaveDevice(request.provenance)) {
            try std.testing.expectEqual(Decision{ .route = .remote }, decision);
        } else {
            try std.testing.expectEqual(Decision{ .hold = .would_leave_device }, decision);
        }
    }
}

test "the backends are ordered by disclosure" {
    try std.testing.expect(!Backend.local_small.leavesDevice());
    try std.testing.expect(!Backend.local_large.leavesDevice());
    try std.testing.expect(Backend.remote.leavesDevice());
}
