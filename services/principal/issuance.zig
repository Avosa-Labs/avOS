//! Issuing an agent's manifest at provisioning: the account signs the authority a person approved, and the
//! signed contract lives with the agent so the capability service can enforce it.
//!
//! Provisioning decides *whether* an envelope is permitted; this turns a permitted envelope into a grant.
//! The account derives the concrete manifest the envelope expresses, endorses it — the account's key signs
//! the manifest's content hash through a custody-held signer, never touching the private key itself — and
//! stores the endorsed manifest with the agent principal. Acceptance of that manifest is the grant: a
//! capability absent from it has no authority at all, so the capability service enforces deny-by-default by
//! reading the manifest rather than trusting the caller.
//!
//! Two rules make the grant honest over its life. Widening is re-consent: a re-provision that asks for more
//! authority than the accepted manifest holds is a new contract, held pending until a person accepts it,
//! while the agent keeps only its old authority in the meantime; a re-provision that only narrows applies
//! at once. And revocation is one act that fans out to every surface — the principal's status and
//! generation, the shared revocation set the enforcement path reads, and the cached endorsement decision —
//! so a revoked agent is inert everywhere it presented itself, on the next operation, not the next restart.
//!
//! Enforcement here is substrate-neutral by construction: a grant is a property of the manifest and the
//! principal, and nothing on this path reads which mind backs the agent, so the same decision holds whether
//! a model, a local model, or a device controller is thinking for it.

const std = @import("std");
const core = @import("core");
const provisioning = @import("provisioning.zig");
const account = @import("../account/creation.zig");
const manifest_issue = @import("manifest_issue.zig");

const manifest = core.trust.manifest;
const grant = core.trust.grant;
const principal = core.principal;
const identity = core.identity;
const time = core.time;

pub const Error = error{UnknownRole} || manifest.Error || std.mem.Allocator.Error || core.outcome.DomainError;

/// Everything a single provisioning act needs: who asks, what body and role the agent has, the envelope a
/// person approved and the account policy that bounds it, the agent's own public key and expiry, and the
/// idempotency key that makes a re-driven request return the identity it already minted.
pub const Request = struct {
    issuer: provisioning.Issuer,
    kind: provisioning.Kind,
    role: []const u8,
    envelope: provisioning.AuthorityEnvelope,
    policy: account.PolicyDomain,
    expires_at: ?time.Timestamp,
    agent_public_key: [manifest.public_key_bytes]u8,
    idempotency_key: u128,
};

/// What a fresh provisioning act resolves to: a new agent principal with an accepted, endorsed manifest, or
/// a refusal — the same refusal the provisioning decision produces, returned before any identity or
/// manifest is minted.
pub const Outcome = union(enum) {
    provisioned: identity.PrincipalId,
    refused: provisioning.Refusal,
};

/// What a re-provision of an existing agent resolves to.
pub const Reprovision = union(enum) {
    /// The envelope exceeded the account policy; nothing changed.
    refused: provisioning.Refusal,
    /// The candidate only narrows the accepted manifest; it was re-endorsed and applied at once.
    narrowed,
    /// The candidate widens the accepted manifest; it is held pending fresh human acceptance, and the
    /// agent keeps only its previously accepted authority until then.
    awaiting_acceptance,
};

/// Why an operation was denied. A capability the manifest does not name has no grant at all; an agent whose
/// manifest expired, whose principal is suspended, revoked, or past expiry, or whose endorsement no longer
/// verifies is inert.
pub const Reason = enum { no_grant, inert };

/// The enforcement decision for one operation: the approval class it runs under, or why it was denied.
pub const Decision = union(enum) {
    granted: manifest.ActionClass,
    denied: Reason,

    pub fn isGranted(decision: Decision) bool {
        return decision == .granted;
    }
};

/// One agent's accepted manifest: the derived manifest and the arrays it borrows, the account's endorsement
/// over its content hash, and a memo of the principal generation at which that endorsement last verified so
/// the Ed25519 check runs once per identity rather than on every gated operation.
const Accepted = struct {
    derived: manifest_issue.Derived,
    endorsement: manifest.Endorsement,
    hash: [manifest.digest_bytes]u8,
    verified_at_generation: ?u64,
};

/// The provisioner: it enrolls agent principals into the shared registry, issues and stores their endorsed
/// manifests, and enforces them. It borrows the principal registry (the authority on identity, status, and
/// generation) and owns the manifest store and the revocation set the enforcement path consults.
pub const Provisioner = struct {
    gpa: std.mem.Allocator,
    registry: *principal.Registry,
    account: identity.PrincipalId,
    account_public_key: [manifest.public_key_bytes]u8,
    account_signer: manifest.Signer,
    policy_domain: []const u8,
    accepted: std.AutoHashMapUnmanaged(u128, Accepted) = .empty,
    pending: std.AutoHashMapUnmanaged(u128, manifest_issue.Derived) = .empty,
    applied: std.AutoHashMapUnmanaged(u128, u128) = .empty,
    revocations: grant.Revocations = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        registry: *principal.Registry,
        acct: identity.PrincipalId,
        account_public_key: [manifest.public_key_bytes]u8,
        account_signer: manifest.Signer,
        policy_domain: []const u8,
    ) Provisioner {
        return .{
            .gpa = gpa,
            .registry = registry,
            .account = acct,
            .account_public_key = account_public_key,
            .account_signer = account_signer,
            .policy_domain = policy_domain,
        };
    }

    pub fn deinit(self: *Provisioner) void {
        var accepted = self.accepted.valueIterator();
        while (accepted.next()) |entry| entry.derived.deinit(self.gpa);
        self.accepted.deinit(self.gpa);
        var pending = self.pending.valueIterator();
        while (pending.next()) |candidate| candidate.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.applied.deinit(self.gpa);
        self.revocations.deinit(self.gpa);
        self.* = undefined;
    }

    /// Provisions a new agent: refuse an envelope beyond the account policy before minting anything, then
    /// enroll the agent principal, derive its manifest, endorse it with the account key, and store it as
    /// accepted. Keyed by the idempotency key, so a recovery re-drive returns the same agent and neither
    /// enrolls a second identity nor re-endorses.
    pub fn provision(self: *Provisioner, request: Request) Error!Outcome {
        if (self.applied.get(request.idempotency_key)) |existing| {
            return .{ .provisioned = .{ .value = existing } };
        }

        // The manifest is issued only for an approved envelope: a refusal returns before any identity or
        // manifest exists, so a request beyond policy leaves no trace.
        switch (provisioning.decide(request.issuer, request.envelope, request.policy)) {
            .refuse => |refusal| return .{ .refused = refusal },
            .provision => {},
        }

        const agent = try self.registry.enroll(.{
            .kind = manifest_issue.principalKind(request.kind),
            .display_name = request.role,
            .policy_domain = self.policy_domain,
            .expires_at = request.expires_at,
            .issuer = self.account,
            .public_key = request.agent_public_key,
        });

        // A failure past enrollment leaves an agent principal with no manifest — no grant — so revoke it
        // rather than leave standing identity nobody endorsed.
        self.issue(agent, request) catch |err| {
            self.registry.revoke(agent) catch {};
            return err;
        };
        try self.applied.put(self.gpa, request.idempotency_key, agent.value);
        return .{ .provisioned = agent };
    }

    /// Re-provisions an existing agent against a fresh envelope. Refuse anything beyond the account policy;
    /// a candidate that widens the accepted manifest is held pending human acceptance; one that only
    /// narrows is re-endorsed and applied at once.
    pub fn reprovision(self: *Provisioner, agent: identity.PrincipalId, request: Request) Error!Reprovision {
        switch (provisioning.decide(request.issuer, request.envelope, request.policy)) {
            .refuse => |refusal| return .{ .refused = refusal },
            .provision => {},
        }

        const existing = self.accepted.getPtr(agent.value) orelse {
            // No prior manifest: an ordinary first issuance for an already-enrolled agent.
            try self.issue(agent, request);
            return .narrowed;
        };

        var candidate = try self.derive(agent, request);
        errdefer candidate.deinit(self.gpa);

        if (candidate.manifest.widensBeyond(existing.derived.manifest)) {
            if (self.pending.getPtr(agent.value)) |prior| prior.deinit(self.gpa);
            try self.pending.put(self.gpa, agent.value, candidate);
            return .awaiting_acceptance;
        }

        // Narrowing applies without fresh acceptance, but the hash changed so the endorsement is re-signed.
        const endorsement = try manifest.endorseWith(self.account_signer, self.account, candidate.manifest);
        existing.derived.deinit(self.gpa);
        existing.* = .{
            .derived = candidate,
            .endorsement = endorsement,
            .hash = candidate.manifest.hash(),
            .verified_at_generation = null,
        };
        return .narrowed;
    }

    /// Accepts a pending widened manifest — the fresh human acceptance a widening requires. Endorses the
    /// candidate and replaces the accepted manifest with it. Returns false when nothing is pending.
    pub fn accept(self: *Provisioner, agent: identity.PrincipalId) Error!bool {
        const removed = self.pending.fetchRemove(agent.value) orelse return false;
        var candidate = removed.value;
        errdefer candidate.deinit(self.gpa);

        const endorsement = try manifest.endorseWith(self.account_signer, self.account, candidate.manifest);
        const record: Accepted = .{
            .derived = candidate,
            .endorsement = endorsement,
            .hash = candidate.manifest.hash(),
            .verified_at_generation = null,
        };
        if (self.accepted.getPtr(agent.value)) |existing| {
            existing.derived.deinit(self.gpa);
            existing.* = record;
        } else {
            try self.accepted.put(self.gpa, agent.value, record);
        }
        return true;
    }

    /// Enforces the accepted manifest for one operation — the check the capability service makes on every
    /// gated call. Deny-by-default: a capability the manifest does not name has no grant. Then fail closed
    /// on an expired manifest, a principal that cannot act, a revoked principal, or an endorsement that no
    /// longer verifies. The endorsement's Ed25519 verification is memoized per principal generation so it
    /// does not run in the hot path, while the deny-by-default and revocation checks run every call.
    pub fn enforce(self: *Provisioner, agent: identity.PrincipalId, capability_name: []const u8) Decision {
        const entry = self.accepted.getPtr(agent.value) orelse return .{ .denied = .no_grant };
        const class = entry.derived.manifest.classOf(capability_name) orelse return .{ .denied = .no_grant };

        const now = self.registry.clock.wall();
        if (!entry.derived.manifest.active(now)) return .{ .denied = .inert };

        const agent_principal = self.registry.authorize(agent) catch return .{ .denied = .inert };
        if (self.revocations.isRevoked(identity.CapabilityId.none, agent)) return .{ .denied = .inert };

        if (entry.verified_at_generation == null or entry.verified_at_generation.? != agent_principal.generation) {
            manifest.verify(entry.derived.manifest, self.account_public_key, entry.endorsement) catch return .{ .denied = .inert };
            entry.verified_at_generation = agent_principal.generation;
        }
        return .{ .granted = class };
    }

    /// Revokes an agent in one act that fans out to every surface it presented itself on: its principal
    /// status and generation, the shared revocation set the enforcement path reads, and the cached
    /// endorsement decision. The agent's identity key is destroyed by the caller that holds the keystore —
    /// this layer holds no key material — completing the kill path.
    pub fn revokeAgent(self: *Provisioner, agent: identity.PrincipalId) Error!void {
        self.registry.revoke(agent) catch {};
        try self.revocations.revokePrincipal(self.gpa, agent);
        if (self.accepted.getPtr(agent.value)) |entry| entry.verified_at_generation = null;
    }

    /// Suspends an agent: it keeps its identity and accepted manifest but cannot act until reinstated. The
    /// cached endorsement decision is invalidated so the next operation re-checks against live status.
    pub fn suspendAgent(self: *Provisioner, agent: identity.PrincipalId) Error!void {
        try self.registry.suspendPrincipal(agent);
        if (self.accepted.getPtr(agent.value)) |entry| entry.verified_at_generation = null;
    }

    /// Reinstates a suspended agent, restoring exactly the authority its accepted manifest holds.
    pub fn reinstateAgent(self: *Provisioner, agent: identity.PrincipalId) Error!void {
        try self.registry.reinstate(agent);
    }

    /// The accepted manifest for an agent, for a caller that reads authority directly. Null when the agent
    /// has none.
    pub fn acceptedManifest(self: *const Provisioner, agent: identity.PrincipalId) ?manifest.Manifest {
        const entry = self.accepted.get(agent.value) orelse return null;
        return entry.derived.manifest;
    }

    /// The enforcement seam over this provisioner's accepted-manifest store, for a separate service — the
    /// capability service — to gate on without depending on the principal service. It borrows the
    /// provisioner, which must outlive every holder of the gate. No allocation: the gate is a context
    /// pointer and a function pointer.
    pub fn gate(self: *Provisioner) core.trust.enforcement.Gate {
        return .{ .context = self, .decide = gateDecide };
    }

    /// Maps `enforce` onto the neutral ruling the seam speaks. A principal with no accepted manifest is
    /// `ungoverned` — a human root or system caller the capability service must not deny by default; a
    /// governed agent resolves to `granted` or `denied` exactly as `enforce` decides, so revocation,
    /// expiry, and endorsement failure all fail closed here too.
    fn gateDecide(context: *anyopaque, agent: u128, capability_name: []const u8) core.trust.enforcement.Ruling {
        const self: *Provisioner = @ptrCast(@alignCast(context));
        const id: identity.PrincipalId = .{ .value = agent };
        if (self.accepted.getPtr(agent) == null) return .ungoverned;
        return switch (self.enforce(id, capability_name)) {
            .granted => .granted,
            .denied => .denied,
        };
    }

    /// Whether the agent's accepted manifest still verifies against the account key — the endorsement is
    /// the account's, over this exact manifest. False when the agent has no accepted manifest.
    pub fn endorsementValid(self: *const Provisioner, agent: identity.PrincipalId) bool {
        const entry = self.accepted.get(agent.value) orelse return false;
        manifest.verify(entry.derived.manifest, self.account_public_key, entry.endorsement) catch return false;
        return true;
    }

    fn derive(self: *Provisioner, agent: identity.PrincipalId, request: Request) Error!manifest_issue.Derived {
        return manifest_issue.derive(self.gpa, .{
            .kind = request.kind,
            .role = request.role,
            .envelope = request.envelope,
            .subject = agent,
            .issuer = self.account,
            .agent_public_key = request.agent_public_key,
            .expires_at = request.expires_at,
        });
    }

    fn issue(self: *Provisioner, agent: identity.PrincipalId, request: Request) Error!void {
        var derived = try self.derive(agent, request);
        errdefer derived.deinit(self.gpa);
        const endorsement = try manifest.endorseWith(self.account_signer, self.account, derived.manifest);
        try self.accepted.put(self.gpa, agent.value, .{
            .derived = derived,
            .endorsement = endorsement,
            .hash = derived.manifest.hash(),
            .verified_at_generation = null,
        });
    }
};

// --- Tests ---

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

/// A signer backing `manifest.Signer` with an in-process key pair, standing in for the keystore over a
/// secure element that holds the account's endorsement key in production. The provisioning path only ever
/// sees signatures, never the key.
const KeyCustody = struct {
    key: Ed25519.KeyPair,

    fn signFor(context: *anyopaque, digest: [manifest.digest_bytes]u8) ?[manifest.signature_bytes]u8 {
        const self: *KeyCustody = @ptrCast(@alignCast(context));
        const signature = self.key.sign(&digest, null) catch return null;
        return signature.toBytes();
    }

    fn signer(self: *KeyCustody) manifest.Signer {
        return .{ .context = self, .signFn = signFor };
    }
};

const Harness = struct {
    ids: identity.Source,
    clock: time.ManualClock,
    registry: principal.Registry,
    custody: KeyCustody,
    provisioner: Provisioner,
    account: identity.PrincipalId,

    fn init(self: *Harness) !void {
        self.ids = .initDeterministic(1);
        self.clock = .init(.fromSeconds(1_000));
        self.registry = .init(testing.allocator, &self.ids, self.clock.clock());
        self.custody = .{ .key = try Ed25519.KeyPair.generateDeterministic(@splat(3)) };
        const account_public_key = self.custody.key.public_key.toBytes();
        self.account = try self.registry.enroll(.{
            .kind = .human,
            .display_name = "owner",
            .policy_domain = "personal",
            .public_key = account_public_key,
        });
        self.provisioner = Provisioner.init(
            testing.allocator,
            &self.registry,
            self.account,
            account_public_key,
            self.custody.signer(),
            "personal",
        );
    }

    fn deinit(self: *Harness) void {
        self.provisioner.deinit();
        self.registry.deinit();
    }

    fn agentKey(seed: u8) [manifest.public_key_bytes]u8 {
        const pair = Ed25519.KeyPair.generateDeterministic(@splat(seed)) catch unreachable;
        return pair.public_key.toBytes();
    }

    fn request(self: *Harness, role: []const u8, envelope: provisioning.AuthorityEnvelope, policy: account.PolicyDomain, key_seed: u8, idem: u128) Request {
        _ = self;
        return .{
            .issuer = .human,
            .kind = .application_bound,
            .role = role,
            .envelope = envelope,
            .policy = policy,
            .expires_at = .fromSeconds(10_000),
            .agent_public_key = agentKey(key_seed),
            .idempotency_key = idem,
        };
    }
};

test "a provisioned agent has a verifiable endorsed manifest the capability service can enforce" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const outcome = try h.provisioner.provision(h.request("Calendar agent", .{}, .{}, 10, 0x1));
    const agent = switch (outcome) {
        .provisioned => |id| id,
        .refused => return error.TestUnexpectedResult,
    };

    // The endorsement is the account's, over this exact manifest.
    try testing.expect(h.provisioner.endorsementValid(agent));

    // Deny-by-default: a cataloged read is granted at its class; a capability the manifest never named has
    // no grant; a consequential capability the conservative envelope dropped has no grant.
    try testing.expectEqual(Decision{ .granted = .silent }, h.provisioner.enforce(agent, "calendar.read"));
    try testing.expectEqual(Decision{ .denied = .no_grant }, h.provisioner.enforce(agent, "files.delete"));
    try testing.expectEqual(Decision{ .denied = .no_grant }, h.provisioner.enforce(agent, "calendar.commit"));
}

test "provisioning leaks nothing when an allocation fails at any step" {
    // Every fallible step registers its cleanup before it runs — the registry and the provisioner both
    // deinit on scope exit — so a failure enrolling the agent, deriving its manifest, or recording either
    // the accepted manifest or the idempotency key releases everything it had taken.
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var ids: identity.Source = .initDeterministic(1);
            var clock: time.ManualClock = .init(.fromSeconds(1_000));
            var registry: principal.Registry = .init(gpa, &ids, clock.clock());
            defer registry.deinit();
            var custody: KeyCustody = .{ .key = try Ed25519.KeyPair.generateDeterministic(@splat(3)) };
            const account_public_key = custody.key.public_key.toBytes();
            const acct = try registry.enroll(.{
                .kind = .human,
                .display_name = "owner",
                .policy_domain = "personal",
                .public_key = account_public_key,
            });
            var provisioner: Provisioner = .init(gpa, &registry, acct, account_public_key, custody.signer(), "personal");
            defer provisioner.deinit();

            const outcome = try provisioner.provision(.{
                .issuer = .human,
                .kind = .application_bound,
                .role = "Calendar agent",
                .envelope = .{},
                .policy = .{},
                .expires_at = .fromSeconds(10_000),
                .agent_public_key = Harness.agentKey(10),
                .idempotency_key = 0x1,
            });
            try testing.expect(outcome == .provisioned);
        }
    }.run, .{});
}

test "a re-driven provision returns the same agent and endorses nothing new" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const first = try h.provisioner.provision(h.request("Mail agent", .{}, .{}, 11, 0x7));
    const again = try h.provisioner.provision(h.request("Mail agent", .{}, .{}, 11, 0x7));
    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(u32, 1), h.provisioner.accepted.count());
}

test "a widened re-provision is a new manifest requiring fresh acceptance" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // Provision conservatively: the consequential commit is not in the accepted manifest.
    const outcome = try h.provisioner.provision(h.request("Calendar agent", .{}, .{}, 12, 0x2));
    const agent = outcome.provisioned;
    try testing.expectEqual(Decision{ .denied = .no_grant }, h.provisioner.enforce(agent, "calendar.commit"));

    // Re-provision asking for consequential authority under a policy that now grants it: this widens.
    const open: account.PolicyDomain = .{ .consequential_granted = true };
    const wider = h.request("Calendar agent", .{ .consequential = true, .approval = .hold }, open, 12, 0x3);
    try testing.expectEqual(Reprovision.awaiting_acceptance, try h.provisioner.reprovision(agent, wider));

    // Until the person accepts, the agent keeps only its old authority — the commit still has no grant.
    try testing.expectEqual(Decision{ .denied = .no_grant }, h.provisioner.enforce(agent, "calendar.commit"));

    // Fresh acceptance promotes the widened manifest, and now the commit is granted at its floor.
    try testing.expect(try h.provisioner.accept(agent));
    try testing.expectEqual(Decision{ .granted = .hold }, h.provisioner.enforce(agent, "calendar.commit"));
    try testing.expect(h.provisioner.endorsementValid(agent));
}

test "a narrowing re-provision applies at once without fresh acceptance" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open: account.PolicyDomain = .{ .consequential_granted = true };
    const outcome = try h.provisioner.provision(h.request("Calendar agent", .{ .consequential = true, .approval = .hold }, open, 13, 0x4));
    const agent = outcome.provisioned;
    try testing.expectEqual(Decision{ .granted = .hold }, h.provisioner.enforce(agent, "calendar.commit"));

    // Narrow back to conservative: no widening, so it applies immediately and the commit drops.
    const narrower = h.request("Calendar agent", .{}, open, 13, 0x5);
    try testing.expectEqual(Reprovision.narrowed, try h.provisioner.reprovision(agent, narrower));
    try testing.expectEqual(Decision{ .denied = .no_grant }, h.provisioner.enforce(agent, "calendar.commit"));
    try testing.expect(h.provisioner.endorsementValid(agent));
}

test "an envelope beyond the account policy is refused before any manifest is issued" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // A fresh account withholds consequential authority; asking for it is refused.
    const outcome = try h.provisioner.provision(h.request("Files agent", .{ .consequential = true }, .{}, 14, 0x6));
    try testing.expectEqual(Outcome{ .refused = .consequential_beyond_account }, outcome);

    // Nothing was minted: no manifest, and the registry still holds only the account principal.
    try testing.expectEqual(@as(u32, 0), h.provisioner.accepted.count());
    try testing.expectEqual(@as(usize, 1), h.registry.count());
}

test "revoking an agent makes it inert everywhere on the next operation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const outcome = try h.provisioner.provision(h.request("Mail agent", .{}, .{}, 15, 0x8));
    const agent = outcome.provisioned;
    try testing.expectEqual(Decision{ .granted = .silent }, h.provisioner.enforce(agent, "mail.read"));

    try h.provisioner.revokeAgent(agent);

    // The manifest is cryptographically intact, but the agent is inert: the kill path denies before the
    // grant is honoured, across every capability it held.
    try testing.expect(h.provisioner.endorsementValid(agent));
    try testing.expectEqual(Decision{ .denied = .inert }, h.provisioner.enforce(agent, "mail.read"));
    try testing.expect(h.provisioner.revocations.isRevoked(identity.CapabilityId.none, agent));
}

test "suspension makes an agent inert and reinstatement restores it exactly" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const outcome = try h.provisioner.provision(h.request("Mail agent", .{}, .{}, 16, 0x9));
    const agent = outcome.provisioned;

    try h.provisioner.suspendAgent(agent);
    try testing.expectEqual(Decision{ .denied = .inert }, h.provisioner.enforce(agent, "mail.read"));

    try h.provisioner.reinstateAgent(agent);
    try testing.expectEqual(Decision{ .granted = .silent }, h.provisioner.enforce(agent, "mail.read"));
}

test "the enforcement gate rules ungoverned, granted, and denied over the accepted-manifest store" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const enforcement = core.trust.enforcement;
    const gate = h.provisioner.gate();

    const agent = (try h.provisioner.provision(h.request("Mail agent", .{}, .{}, 20, 0xC))).provisioned;

    // A governed agent: a cataloged read is granted, a capability its manifest never named is denied.
    try testing.expectEqual(enforcement.Ruling.granted, gate.rule(agent.value, "mail.read"));
    try testing.expectEqual(enforcement.Ruling.denied, gate.rule(agent.value, "files.delete"));

    // A principal with no accepted manifest — the account root — is ungoverned, not denied by default.
    try testing.expectEqual(enforcement.Ruling.ungoverned, gate.rule(h.account.value, "mail.read"));

    // Revocation fails closed on the next ruling, across every capability the agent held.
    try h.provisioner.revokeAgent(agent);
    try testing.expectEqual(enforcement.Ruling.denied, gate.rule(agent.value, "mail.read"));
}

test "a tampered manifest disables the agent through the gate" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const enforcement = core.trust.enforcement;
    const gate = h.provisioner.gate();
    const agent = (try h.provisioner.provision(h.request("Mail agent", .{}, .{}, 21, 0xD))).provisioned;
    try testing.expectEqual(enforcement.Ruling.granted, gate.rule(agent.value, "mail.read"));

    // Corrupt the stored endorsement before it is memoized: the signature no longer covers the manifest,
    // so the endorsement fails to verify and the agent is inert on the next ruling.
    const entry = h.provisioner.accepted.getPtr(agent.value).?;
    entry.verified_at_generation = null;
    entry.endorsement.signature[0] ^= 0xFF;
    try testing.expectEqual(enforcement.Ruling.denied, gate.rule(agent.value, "mail.read"));
}

test "substrate-neutrality through the gate: two minds with one manifest rule identically" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const gate = h.provisioner.gate();
    const a = (try h.provisioner.provision(h.request("Web research agent", .{}, .{}, 22, 0xE))).provisioned;
    const b = (try h.provisioner.provision(h.request("Web research agent", .{}, .{}, 23, 0xF))).provisioned;
    try testing.expectEqual(gate.rule(a.value, "web.read"), gate.rule(b.value, "web.read"));
    try testing.expectEqual(gate.rule(a.value, "files.delete"), gate.rule(b.value, "files.delete"));
}

test "substrate-neutrality: the grant is a property of the manifest, not of any mind" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // Two agents with the same role and envelope — imagine different minds behind them — resolve
    // identically, because enforcement reads the manifest and the principal, never the mind.
    const a = (try h.provisioner.provision(h.request("Web research agent", .{}, .{}, 17, 0xA))).provisioned;
    const b = (try h.provisioner.provision(h.request("Web research agent", .{}, .{}, 18, 0xB))).provisioned;
    try testing.expectEqual(h.provisioner.enforce(a, "web.read"), h.provisioner.enforce(b, "web.read"));
    try testing.expectEqual(h.provisioner.enforce(a, "web.fetch"), h.provisioner.enforce(b, "web.fetch"));
    try testing.expectEqual(h.provisioner.enforce(a, "files.delete"), h.provisioner.enforce(b, "files.delete"));
}
