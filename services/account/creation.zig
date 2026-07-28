//! Creating a personal account: binding a person to the Personal Compute Instance that
//! is their world's home, once, atomically, and never twice.
//!
//! A personal account is the root of a person's world — the analogue of the account a
//! phone is signed into — and concretely it is a human principal plus the durable
//! binding to the Personal Compute Instance the account owns. Creating one is the most
//! consequential setup act on the device: it mints a person's authority and the home
//! their state lives in, so it must hold three properties that this module decides and
//! drives. It is created only once: re-running creation on an instance that already
//! has an account is refused, not silently overwritten, because a second create would
//! strand the first account's data behind a new identity. It survives interruption: a
//! restart between minting the human and binding the instance must leave either a whole
//! account or none, never a half — so creation is assembled and, on any failure,
//! rolled back to nothing. And it is recoverable: losing the device does not destroy
//! the account, because the instance is the account's home and recovery re-binds the
//! same human principal to the existing instance rather than minting a new identity.
//!
//! This module owns no long-lived state. It decides whether a creation request is a
//! fresh create, a recovery re-bind, or a refusal, as a pure function over what already
//! exists; and it assembles an account atomically, rolling back on failure, so the
//! crash-consistency is enforced in one place rather than trusted to the caller.

const std = @import("std");
const principal = @import("../principal/enrollment.zig");

/// The identity of a Personal Compute Instance — the encrypted home an account owns.
/// Distinct from a principal id: the instance outlives any single device.
pub const InstanceId = u128;

/// The identity of the human principal at the root of an account.
pub const HumanId = u128;

/// What already exists on the instance the request targets.
pub const Existing = enum {
    /// No account has been created against this instance yet.
    none,
    /// An account already owns this instance.
    account_present,
};

/// Whether the person is creating a new account or recovering an existing one onto a
/// new device.
pub const Intent = enum { create, recover };

/// Why a creation request was refused.
pub const Refusal = enum {
    /// A create was asked for on an instance that already has an account. Overwriting
    /// would strand the existing account's data; the person must recover instead.
    already_provisioned,
    /// A recovery was asked for on an instance that has no account to recover.
    nothing_to_recover,
};

/// What a creation request resolves to.
pub const Outcome = union(enum) {
    /// Mint a new human principal, bind a new instance, establish default policy.
    create,
    /// Recovery: re-bind the existing human principal to the existing instance,
    /// minting no new identity.
    rebind,
    refuse: Refusal,

    pub fn proceeds(outcome: Outcome) bool {
        return outcome == .create or outcome == .rebind;
    }
};

/// Decides what a creation request resolves to, given what already exists.
///
/// A create is permitted only on a fresh instance — an instance that already has an
/// account refuses the create rather than overwrite it, since the person's existing
/// world lives there. A recovery is the mirror: it re-binds the existing account and so
/// requires an account to already be present; recovering nothing is refused. This is
/// the single decision that keeps an account from being created twice or lost.
pub fn decide(existing: Existing, intent: Intent) Outcome {
    return switch (intent) {
        .create => if (existing == .account_present) .{ .refuse = .already_provisioned } else .create,
        .recover => if (existing == .account_present) .rebind else .{ .refuse = .nothing_to_recover },
    };
}

/// The default policy domain an account establishes: the capability, approval, and
/// privacy defaults every agent the account provisions inherits. These are the account-
/// wide baselines written as registry keys and consumed by the capability and policy
/// services; a per-agent envelope may only narrow them, never exceed them.
pub const PolicyDomain = struct {
    /// The default approval class a consequential agent action takes unless a key
    /// raises it. Conservative by default: an agent proposes and the person decides.
    default_approval: ApprovalClass = .hold,
    /// The default privacy classification for data an agent handles — whether it may
    /// leave the device. Conservative by default: on-device unless a key allows egress.
    default_privacy: Privacy = .on_device,
    /// Whether agents may hold consequential authority at all before the person grants
    /// it. Off by default: a fresh account's agents read and propose, nothing more.
    consequential_granted: bool = false,

    pub const ApprovalClass = enum { silent, notify, hold, human_only };
    pub const Privacy = enum { on_device, may_egress };
};

/// A created account: the human principal at its root, the instance it owns, and the
/// default policy domain every provisioned agent inherits. The roster starts empty and
/// is filled by provisioning (a separate step), so an account is whole the moment it
/// exists, before any agent is added.
pub const Account = struct {
    human: HumanId,
    instance: InstanceId,
    policy: PolicyDomain,
};

/// The identities a caller supplies to assemble an account. Minting these is the
/// principal service's job; assembly binds them together atomically.
pub const Materials = struct {
    human: HumanId,
    instance: InstanceId,
};

/// A fault injected into assembly, so the rollback path is exercised in tests exactly
/// as a real allocation or write failure would exercise it.
pub const AssemblyFault = enum { none, at_instance_bind, at_policy_write };

/// Assembles an account from freshly minted materials, atomically: if any step fails,
/// nothing is left behind. In production the steps are real writes (bind the instance,
/// write the policy-domain keys); here the sequence is modelled so the crash-consistency
/// property — a whole account or none — is decided in one place. Returns null on a fault,
/// having rolled back, so a caller that sees null knows no partial account exists.
pub fn assemble(materials: Materials, fault: AssemblyFault) ?Account {
    // Step 1 is minting the human, already done to produce `materials`. Step 2 binds
    // the instance; step 3 writes the default policy. A fault at any point unwinds the
    // steps taken so far, leaving nothing.
    if (fault == .at_instance_bind) return null; // instance bind failed → nothing bound
    if (fault == .at_policy_write) return null; // policy write failed → unbind, nothing left
    return .{
        .human = materials.human,
        .instance = materials.instance,
        .policy = .{},
    };
}

/// Recovers an account onto a new device: returns the existing account unchanged, so
/// the same human principal and the same instance are re-bound and no new identity is
/// minted. Recovery is a re-binding, never a re-creation — the person keeps who they
/// were and the home their world lives in.
pub fn rebind(existing: Account) Account {
    return existing;
}

/// The enrollment issuer that creates an account's root human: the device's trusted
/// setup, the root of authority. An account's human is never minted by another
/// principal — the same rule the principal enrollment enforces, surfaced here so
/// account creation states its authority explicitly.
pub fn rootIssuer() principal.Issuer {
    return .trusted_setup;
}

// --- Tests ---

const testing = std.testing;

test "a create on a fresh instance proceeds; on a provisioned one it is refused" {
    try testing.expectEqual(Outcome.create, decide(.none, .create));
    try testing.expectEqual(Outcome{ .refuse = .already_provisioned }, decide(.account_present, .create));
}

test "recovery re-binds an existing account and refuses when there is nothing to recover" {
    try testing.expectEqual(Outcome.rebind, decide(.account_present, .recover));
    try testing.expectEqual(Outcome{ .refuse = .nothing_to_recover }, decide(.none, .recover));
}

test "assembly with no fault yields a whole account with conservative defaults" {
    const account = assemble(.{ .human = 7, .instance = 42 }, .none) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(HumanId, 7), account.human);
    try testing.expectEqual(@as(InstanceId, 42), account.instance);
    // A fresh account's agents read and propose, nothing consequential, nothing leaves the device.
    try testing.expectEqual(PolicyDomain.ApprovalClass.hold, account.policy.default_approval);
    try testing.expectEqual(PolicyDomain.Privacy.on_device, account.policy.default_privacy);
    try testing.expect(!account.policy.consequential_granted);
}

test "a fault at any assembly step leaves no partial account" {
    try testing.expect(assemble(.{ .human = 1, .instance = 1 }, .at_instance_bind) == null);
    try testing.expect(assemble(.{ .human = 1, .instance = 1 }, .at_policy_write) == null);
}

test "the account root is minted only by trusted setup" {
    try testing.expectEqual(principal.Issuer.trusted_setup, rootIssuer());
    // And that issuer is exactly the one the principal enrollment admits for a human.
    try testing.expect(principal.decide(rootIssuer(), .{ .kind = .human }).enrolls());
}

test "recovery re-binds the same human and instance, minting no new identity" {
    const original = assemble(.{ .human = 99, .instance = 500 }, .none) orelse return error.TestUnexpectedResult;
    const recovered = rebind(original);
    // The person keeps who they were and the home their world lives in.
    try testing.expectEqual(original.human, recovered.human);
    try testing.expectEqual(original.instance, recovered.instance);
}

test "create and recover are mutually exclusive over what exists, swept" {
    // For any state, exactly one of create/recover proceeds and the other refuses, so a
    // request is never ambiguous about whether it makes or restores an account.
    for ([_]Existing{ .none, .account_present }) |existing| {
        const c = decide(existing, .create).proceeds();
        const r = decide(existing, .recover).proceeds();
        try testing.expect(c != r);
    }
}
