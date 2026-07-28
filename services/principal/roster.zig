//! The agent roster: the co-inhabitants a person's account holds, what a fresh account
//! is provisioned with, and what removing one entails.
//!
//! An account is never empty on first run: it is provisioned with a small set of default
//! agents — a general assistant and a few app-bound agents — each a real principal with a
//! conservative envelope, so a person meets a working system rather than a blank one. The
//! roster is where those agents live and where the person, from Settings, adds, removes,
//! and suspends them. Two rules this module makes concrete. Every default agent's envelope
//! is bounded by the account policy, so the system ships no agent more powerful than the
//! account allows — the same bound the provisioning decision enforces for agents a person
//! adds later. And removing an agent is not a hiding: it revokes the agent's capabilities
//! immediately and cancels its in-flight work, so authority actually drops when a person
//! takes it away, rather than lingering behind a removed row.
//!
//! This module holds no live registry — the principal service does. It defines the agent
//! aggregate, the first-run set, and the pure semantics of suspending and removing, so the
//! "conservative by default" and "removal really revokes" properties are stated in one
//! place and tested independently of the service that stores them.

const std = @import("std");
const provisioning = @import("provisioning.zig");
const account = @import("../account/creation.zig");

pub const PrincipalId = u128;

/// An agent's runtime status.
pub const Status = enum {
    /// Provisioned and able to act (within its envelope).
    active,
    /// Suspended by the person: its capabilities are inert until resumed.
    suspended,
    /// Its mind adapter is unavailable (model offline, device unreachable): it cannot
    /// act, and this is shown, never silent.
    mind_unavailable,

    /// Whether an agent in this status may hold live authority. Only an active agent can.
    pub fn canAct(status: Status) bool {
        return status == .active;
    }
};

/// A provisioned agent in the roster.
pub const Agent = struct {
    id: PrincipalId,
    kind: provisioning.Kind,
    envelope: provisioning.AuthorityEnvelope,
    status: Status = .active,
};

/// A default agent the account is provisioned with on first run: a role, its kind, and
/// the envelope it should hold. The envelope is deliberately conservative so it is
/// admissible under any account policy that grants nothing beyond the baseline.
pub const DefaultAgent = struct {
    role: []const u8,
    kind: provisioning.Kind,
    envelope: provisioning.AuthorityEnvelope,
};

/// The agents a fresh account meets on first run. A general assistant with broad read
/// intent and every consequential action held, plus app-bound agents for the apps that
/// are meaningfully agentic — each scoped to its app. All envelopes are conservative:
/// no consequential authority, hold approval, on-device, so they are admissible under
/// the fresh account policy and hold nothing the person did not implicitly allow.
pub const default_agents = [_]DefaultAgent{
    .{ .role = "Assistant", .kind = .assistant, .envelope = .{} },
    .{ .role = "Calendar agent", .kind = .application_bound, .envelope = .{} },
    .{ .role = "Mail agent", .kind = .application_bound, .envelope = .{} },
    .{ .role = "Web research agent", .kind = .application_bound, .envelope = .{} },
    .{ .role = "Files agent", .kind = .application_bound, .envelope = .{} },
};

/// What removing an agent entails: its capabilities must be revoked and its in-flight
/// work cancelled, so authority drops the moment the person removes it. The service acts
/// on this; the module states it so the guarantee is explicit.
pub const Removal = struct {
    /// The removed agent, whose capabilities the capability service must revoke.
    agent: PrincipalId,
    /// That the agent's in-flight tasks must be cancelled (its descendants ended).
    cancel_in_flight: bool,
};

/// The removal a request produces: always revoke and cancel, never a soft hide.
pub fn remove(agent: Agent) Removal {
    return .{ .agent = agent.id, .cancel_in_flight = true };
}

/// Suspends an agent: it keeps its identity and grants but cannot act until resumed. A
/// suspended agent's capabilities are inert, which is a live property of its status, not
/// a revocation — resuming restores it exactly.
pub fn suspend_(agent: Agent) Agent {
    var suspended = agent;
    suspended.status = .suspended;
    return suspended;
}

/// Whether every default agent is admissible under a given account policy — the check
/// that the shipped first-run set never exceeds what the account allows.
pub fn defaultsAdmissible(policy: account.PolicyDomain) bool {
    for (default_agents) |da| {
        if (!provisioning.decide(.human, da.envelope, policy).provisions()) return false;
    }
    return true;
}

// --- Tests ---

const testing = std.testing;

test "a fresh account is provisioned with a working set of default agents" {
    try testing.expect(default_agents.len >= 2);
    // The first is the general assistant; the rest are app-bound.
    try testing.expectEqual(provisioning.Kind.assistant, default_agents[0].kind);
    var app_bound: usize = 0;
    for (default_agents) |da| {
        if (da.kind == .application_bound) app_bound += 1;
    }
    try testing.expect(app_bound >= 1);
}

test "every default agent is admissible under the conservative fresh-account policy" {
    // The system ships no agent more powerful than a fresh account allows.
    try testing.expect(defaultsAdmissible(.{}));
}

test "only an active agent may hold live authority" {
    try testing.expect(Status.active.canAct());
    try testing.expect(!Status.suspended.canAct());
    try testing.expect(!Status.mind_unavailable.canAct());
}

test "removing an agent revokes and cancels, never merely hides" {
    const agent = Agent{ .id = 7, .kind = .assistant, .envelope = .{} };
    const removal = remove(agent);
    try testing.expectEqual(@as(PrincipalId, 7), removal.agent);
    try testing.expect(removal.cancel_in_flight);
}

test "suspending keeps identity and envelope but stops the agent acting" {
    const agent = Agent{ .id = 9, .kind = .application_bound, .envelope = .{ .delegation_depth = 2 } };
    const s = suspend_(agent);
    try testing.expectEqual(agent.id, s.id); // same identity
    try testing.expectEqual(agent.envelope.delegation_depth, s.envelope.delegation_depth); // same grants
    try testing.expect(!s.status.canAct()); // but inert
}
