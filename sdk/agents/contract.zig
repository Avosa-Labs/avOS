//! The agent integration contract: the one interface any agent plugs into, whatever its mind.
//!
//! A cloud model, a local model, or an embodied controller (a robot, a vehicle, an appliance) is
//! the same kind of participant — a principal that proposes work and is governed the same way. The
//! contract has seven clauses, and the point of it is that a third party implements only one of
//! them; the platform already provides the rest:
//!
//!   1. Identity   — the agent registers as a principal (issuer, expiration, agent kind). Provided
//!                   by the principal registry; restart does not mint new authority.
//!   2. Mind       — a model adapter or an embodied controller that produces *proposals*. THIS is
//!                   the part a third party implements, and the part defined here.
//!   3. Validation — proposals are data, validated against the agent's declared tools and policy
//!                   before anything becomes a task, a capability request, or a side effect. No
//!                   agent executes its own output. The tool registry and manifest provide it.
//!   4. Authority  — the agent holds opaque capability handles only, requests authority through the
//!                   capability service, and its consequential actions carry approval classes.
//!                   Provided by the capability service.
//!   5. Visibility — all activity lands in the task graph and the ledger; the live feed derives
//!                   from the ledger, never from the agent's own report. Provided by the ledger.
//!   6. Budgets    — CPU class, memory, model-compute, a monetary ceiling, an interruption budget.
//!                   Provided by the resource service and the capability constraints.
//!   7. Death      — expiration, revocation, and the kill switch end the agent's authority at once.
//!                   Provided by the capability service and principal expiration.
//!
//! So this module defines the mind: what it produces (a proposal, which is data, never an action),
//! and the one structural rule an embodied mind adds — the split between a deliberative mind that
//! plans (and may be remote) and a reflex controller that must run on-device and never wait on a
//! remote model in a latency-critical loop. That split is a type-level rule the capability service
//! enforces at grant time, tested here.

const std = @import("std");

/// Which control path a mind belongs to. The deliberative path plans and may be remote; the reflex
/// path (balance, braking, an obstacle stop) is latency-critical and must run on-device.
pub const ControlClass = enum { deliberative, reflex };

/// Where a mind runs. A reflex mind must be on-device; a deliberative mind may be either.
pub const Locality = enum { on_device, remote };

/// What a mind produces: a proposal, never an action. It names a declared tool and carries the
/// arguments as opaque bytes the platform decodes against that tool's typed schema and checks
/// against policy before anything runs. A mind proposes; it does not execute its own output.
pub const Proposal = struct {
    /// The tool the mind proposes to invoke, by the name it declared in its manifest.
    tool: []const u8,
    /// The proposed arguments, opaque here; the platform validates them against the tool's schema.
    arguments: []const u8 = "",
};

/// A mind: the part of the contract a third party implements. It has a control class and a
/// locality, from which its allowed authority follows. (A running mind also carries a function that
/// produces proposals; that is added with the agent host loop — the governance rules stand on the
/// class and locality alone, which is what this module fixes.)
pub const Mind = struct {
    control_class: ControlClass,
    locality: Locality,

    /// Whether the mind is even coherent: a reflex controller that ran remotely would put a
    /// latency-critical loop across the network, which the contract forbids outright.
    pub fn valid(mind: Mind) bool {
        return mind.control_class != .reflex or mind.locality == .on_device;
    }
};

/// Whether `mind` may be granted a capability of `capability_class`.
///
/// A deliberative capability — planning, reading, proposing — may go to any mind. A reflex
/// capability — one in a latency-critical control loop — may go only to an on-device reflex
/// controller: never to a deliberative mind (which may block on planning) and never to a remote
/// one (which may block on the network). This is the split-brain rule, enforced at grant time so a
/// remote model can never, whatever it holds, sit in a reflex loop.
pub fn mayGrant(mind: Mind, capability_class: ControlClass) bool {
    return switch (capability_class) {
        .deliberative => true,
        .reflex => mind.control_class == .reflex and mind.locality == .on_device,
    };
}

// --- Tests ---

const testing = std.testing;

test "a deliberative capability may be held by any coherent mind" {
    const remote_planner = Mind{ .control_class = .deliberative, .locality = .remote };
    const local_planner = Mind{ .control_class = .deliberative, .locality = .on_device };
    const reflex = Mind{ .control_class = .reflex, .locality = .on_device };
    try testing.expect(mayGrant(remote_planner, .deliberative));
    try testing.expect(mayGrant(local_planner, .deliberative));
    try testing.expect(mayGrant(reflex, .deliberative));
}

test "a reflex capability goes only to an on-device reflex controller" {
    // The on-device reflex controller may hold it.
    try testing.expect(mayGrant(.{ .control_class = .reflex, .locality = .on_device }, .reflex));
    // A deliberative mind may not — it could block on planning inside a reflex loop.
    try testing.expect(!mayGrant(.{ .control_class = .deliberative, .locality = .on_device }, .reflex));
    // A remote mind may not — it could block on the network inside a reflex loop.
    try testing.expect(!mayGrant(.{ .control_class = .deliberative, .locality = .remote }, .reflex));
}

test "a remote reflex mind is not even a coherent mind" {
    try testing.expect(!(Mind{ .control_class = .reflex, .locality = .remote }).valid());
    try testing.expect((Mind{ .control_class = .reflex, .locality = .on_device }).valid());
    try testing.expect((Mind{ .control_class = .deliberative, .locality = .remote }).valid());
    // A capability of any class is refused to an incoherent (remote reflex) mind's reflex path.
    try testing.expect(!mayGrant(.{ .control_class = .reflex, .locality = .remote }, .reflex));
}

test "a proposal is data: it names a tool and carries opaque arguments" {
    const proposal = Proposal{ .tool = "calendar.read", .arguments = "{\"day\":\"today\"}" };
    try testing.expect(proposal.tool.len > 0);
    // Nothing here executes it; a proposal only describes what the mind would ask the platform to do.
    const bare = Proposal{ .tool = "messages.search" };
    try testing.expectEqualStrings("", bare.arguments);
}
