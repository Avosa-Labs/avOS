//! Provisioning an agent: deciding what authority a person may give a co-inhabitant,
//! bounded so a person can never create an agent more powerful than themselves.
//!
//! An agent is created the same way an account is — declared by a person — and what it
//! is comes down to four things: its kind (the body it has, from a disembodied
//! assistant to an embodied device), its mind (the swappable adapter that produces its
//! proposals, decided elsewhere), its authority envelope (the capabilities, budgets,
//! hours, and delegation depth it may hold), and its governance (the approval and
//! privacy rules that apply to it). This module decides whether a requested envelope is
//! permitted, and the rule it enforces is the one the whole safety story rests on: an
//! agent's authority is bounded by the account's policy domain. A person cannot
//! provision an agent that acts more freely than the account allows — cannot grant
//! consequential authority the account withholds, cannot loosen an action below the
//! account's approval floor, cannot let data leave a device the account keeps it on.
//! And provisioning is human-only: an agent cannot silently spawn another agent, so
//! every agent traces back to a person who declared it.
//!
//! This module provisions nothing. It decides whether a provisioning request is
//! permitted, as a pure function over who is asking, the envelope they request, and the
//! account policy that bounds it, so the "never more powerful than the person" property
//! is enforced at one gate.

const std = @import("std");
const account = @import("../account/creation.zig");

/// The kind of agent — the body it has. The mind behind it is a separate, swappable
/// choice; the kind fixes how the agent reaches the world.
pub const Kind = enum {
    /// A mind with no device — the default, backed by a model adapter.
    assistant,
    /// An agent that lives to operate specific apps.
    application_bound,
    /// An embodied agent — a vehicle, robot, appliance, glasses, an IoT unit.
    device,
    /// An agent owned by someone else, reached through a connector.
    external,
};

/// The resource budgets an agent may hold. Zero means "none granted" — an agent with a
/// zero model-token budget cannot call a model at all.
pub const Budget = struct {
    cpu_ms: u64 = 0,
    memory_bytes: u64 = 0,
    model_tokens: u64 = 0,
    monetary_cents: u64 = 0,
};

/// The authority envelope requested for an agent: everything it may hold, each field
/// bounded by the account policy domain.
pub const AuthorityEnvelope = struct {
    /// Whether the agent may hold consequential capabilities at all.
    consequential: bool = false,
    /// The action class the agent's consequential operations take. May be stricter than
    /// the account floor, never weaker.
    approval: account.PolicyDomain.ApprovalClass = .hold,
    /// Whether the agent may handle data that leaves the device. Bounded by the account.
    privacy: account.PolicyDomain.Privacy = .on_device,
    /// The agent's resource budgets.
    budget: Budget = .{},
    /// How many levels deep the agent may delegate its authority. Zero means it may not
    /// delegate at all.
    delegation_depth: u8 = 0,
};

/// Who is requesting the provisioning. Provisioning is human-only, so this is what the
/// gate checks first.
pub const Issuer = enum { human, agent, service };

/// Why a provisioning request was refused.
pub const Refusal = enum {
    /// The issuer is not a human. Provisioning an agent is human-only — an agent may not
    /// spawn another agent, silently or otherwise.
    not_human,
    /// The envelope grants consequential authority the account policy withholds.
    consequential_beyond_account,
    /// The envelope's action class is weaker than the account's approval floor.
    approval_below_account_floor,
    /// The envelope lets data leave a device the account keeps it on.
    privacy_exceeds_account,
};

/// The provisioning decision.
pub const Decision = union(enum) {
    provision,
    refuse: Refusal,

    pub fn provisions(decision: Decision) bool {
        return decision == .provision;
    }
};

/// The restrictiveness order of the approval classes: a higher rank is more restrictive.
/// An agent's action class must be at least as restrictive as the account floor.
fn approvalRank(class: account.PolicyDomain.ApprovalClass) u8 {
    return switch (class) {
        .silent => 0,
        .notify => 1,
        .hold => 2,
        .human_only => 3,
    };
}

/// Decides whether a provisioning request is permitted.
///
/// Provisioning is human-only: a non-human issuer is refused before authority is even
/// considered, so an agent can never spawn an agent. A human's request is then bounded
/// by the account policy on every axis — an agent may not hold consequential authority
/// the account withholds, may not act below the account's approval floor, and may not
/// let data egress a device the account keeps it on. Within those bounds the person is
/// free; past them the request is refused rather than clamped, so a person always sees
/// exactly the authority they asked for or a clear refusal, never a silent reduction.
pub fn decide(issuer: Issuer, requested: AuthorityEnvelope, policy: account.PolicyDomain) Decision {
    if (issuer != .human) return .{ .refuse = .not_human };
    if (requested.consequential and !policy.consequential_granted) {
        return .{ .refuse = .consequential_beyond_account };
    }
    if (approvalRank(requested.approval) < approvalRank(policy.default_approval)) {
        return .{ .refuse = .approval_below_account_floor };
    }
    if (requested.privacy == .may_egress and policy.default_privacy == .on_device) {
        return .{ .refuse = .privacy_exceeds_account };
    }
    return .provision;
}

// --- Tests ---

const testing = std.testing;

/// The conservative default policy a fresh account establishes: hold approval, on-device
/// privacy, no consequential authority.
fn freshPolicy() account.PolicyDomain {
    return .{};
}

test "provisioning is human-only: an agent may not provision an agent" {
    const conservative = AuthorityEnvelope{};
    try testing.expectEqual(Decision{ .refuse = .not_human }, decide(.agent, conservative, freshPolicy()));
    try testing.expectEqual(Decision{ .refuse = .not_human }, decide(.service, conservative, freshPolicy()));
    try testing.expect(decide(.human, conservative, freshPolicy()).provisions());
}

test "an agent cannot be granted consequential authority the account withholds" {
    const wants_consequential = AuthorityEnvelope{ .consequential = true };
    try testing.expectEqual(
        Decision{ .refuse = .consequential_beyond_account },
        decide(.human, wants_consequential, freshPolicy()),
    );
    // Once the account grants consequential authority, the same envelope is permitted.
    var open = freshPolicy();
    open.consequential_granted = true;
    try testing.expect(decide(.human, wants_consequential, open).provisions());
}

test "an agent's action class may tighten the account floor but never loosen it" {
    var account_notify = freshPolicy();
    account_notify.default_approval = .hold;
    // Stricter than the floor (human_only) is fine.
    try testing.expect(decide(.human, .{ .approval = .human_only }, account_notify).provisions());
    // Equal to the floor is fine.
    try testing.expect(decide(.human, .{ .approval = .hold }, account_notify).provisions());
    // Weaker than the floor (notify below hold) is refused.
    try testing.expectEqual(
        Decision{ .refuse = .approval_below_account_floor },
        decide(.human, .{ .approval = .notify }, account_notify),
    );
}

test "an agent may not egress data the account keeps on the device" {
    const wants_egress = AuthorityEnvelope{ .privacy = .may_egress };
    try testing.expectEqual(
        Decision{ .refuse = .privacy_exceeds_account },
        decide(.human, wants_egress, freshPolicy()),
    );
    var may_egress = freshPolicy();
    may_egress.default_privacy = .may_egress;
    try testing.expect(decide(.human, wants_egress, may_egress).provisions());
}

test "no provisioned agent ever exceeds the account policy, swept" {
    // The bounding property: for any envelope a human requests, if it is provisioned then
    // it holds no authority the account policy withholds, on every axis.
    const classes = [_]account.PolicyDomain.ApprovalClass{ .silent, .notify, .hold, .human_only };
    const privacies = [_]account.PolicyDomain.Privacy{ .on_device, .may_egress };
    for ([_]bool{ false, true }) |acct_conseq| {
        for (classes) |acct_class| {
            for (privacies) |acct_priv| {
                const policy = account.PolicyDomain{
                    .default_approval = acct_class,
                    .default_privacy = acct_priv,
                    .consequential_granted = acct_conseq,
                };
                for ([_]bool{ false, true }) |req_conseq| {
                    for (classes) |req_class| {
                        for (privacies) |req_priv| {
                            const env = AuthorityEnvelope{
                                .consequential = req_conseq,
                                .approval = req_class,
                                .privacy = req_priv,
                            };
                            if (decide(.human, env, policy).provisions()) {
                                if (req_conseq) try testing.expect(acct_conseq);
                                try testing.expect(approvalRank(req_class) >= approvalRank(acct_class));
                                if (req_priv == .may_egress) try testing.expect(acct_priv == .may_egress);
                            }
                        }
                    }
                }
            }
        }
    }
}
