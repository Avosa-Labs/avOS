//! The account's cryptographic root: the key an account endorses its agents with, held where the
//! provisioning path can ask for a signature but never read the key.
//!
//! Provisioning turns an approved authority envelope into a signed manifest the capability service
//! enforces (that mapping lives in the principal layer). The one thing that mapping cannot do for itself
//! is hold the account's endorsement key: the account signs each manifest's content hash, and that key must
//! live in the device's secure element, not in the provisioning code. This module is that seam. Establishing
//! an account mints its endorsement key in the keystore and enrolls the root human principal it belongs to,
//! then hands the provisioner three things it cannot fabricate — the account principal, the endorsement
//! key's public half (so a verifier can check the account's signatures), and a custody-held signer over the
//! private half — so every agent the account later provisions is endorsed by a key the provisioning path
//! only ever sees signatures from.
//!
//! The root's endorsement key is a `user_authentication` key: it signs on the person's behalf. The account's
//! human authenticates locally at the device and so carries no authentication key of its own; this key is a
//! distinct one, used only to endorse the manifests the account issues. Establishing an account is atomic —
//! a failure after minting the key or enrolling the human unwinds both, so a half-made account root never
//! stands.

const std = @import("std");
const core = @import("core");
const keystore_mod = @import("security").keystore;
const secure_element = @import("hardware").secure_element;
const issuance = @import("../principal/issuance.zig");
const provisioning = @import("../principal/provisioning.zig");
const roster = @import("../principal/roster.zig");
const creation = @import("creation.zig");

const manifest = core.trust.manifest;
const principal = core.principal;
const identity = core.identity;
const time = core.time;

/// The keystore name of the account's endorsement key. One per account root, owned by the account's human
/// principal, distinct from any key an agent holds.
pub const endorsement_key_name = "account.endorsement";

pub const Error = keystore_mod.Error || issuance.Error;

/// The cryptographic root of an established account: the endorsement key held in custody, the root human
/// principal it belongs to and its public half, and the account policy every agent it provisions is bounded
/// by. It borrows the keystore and the principal registry rather than owning them; establishing the root
/// mints the key and enrolls the human, and the caller keeps the root at a stable address for as long as any
/// provisioner built from it lives, since the provisioner's signer points at the delegate held here.
pub const AccountRoot = struct {
    keystore: *keystore_mod.Keystore,
    registry: *principal.Registry,
    account: identity.PrincipalId,
    public_key: [manifest.public_key_bytes]u8,
    policy: creation.PolicyDomain,
    policy_domain: []const u8,
    delegate: keystore_mod.EndorsementDelegate,

    /// Establishes the account root in place: enrolls the root human, mints its endorsement key, and records
    /// the key's public half. Atomic — a failure minting the key or reading its public half revokes the
    /// human and destroys the key, so nothing partial is left. `condition` is the secure-element condition
    /// the endorsement key is created under (for instance, that the device be unlocked to endorse).
    pub fn establish(
        self: *AccountRoot,
        keystore: *keystore_mod.Keystore,
        registry: *principal.Registry,
        display_name: []const u8,
        policy_domain: []const u8,
        policy: creation.PolicyDomain,
        condition: secure_element.Condition,
    ) Error!void {
        // The root human authenticates locally at the device, so it carries no authentication key of its
        // own; the endorsement key it holds in the element is separate and used only to endorse manifests.
        const account = try registry.enroll(.{
            .kind = .human,
            .display_name = display_name,
            .policy_domain = policy_domain,
        });
        errdefer registry.revoke(account) catch {};

        try keystore.create(account, endorsement_key_name, .user_authentication, condition);
        errdefer keystore.destroy(account, endorsement_key_name) catch {};

        const public_key = try keystore.publicKey(account, endorsement_key_name);

        self.* = .{
            .keystore = keystore,
            .registry = registry,
            .account = account,
            .public_key = public_key,
            .policy = policy,
            .policy_domain = policy_domain,
            .delegate = .{ .keystore = keystore, .owner = account, .name = endorsement_key_name },
        };
    }

    /// The custody-held signer that endorses manifests with the account's key. The key stays in the element;
    /// only signatures cross out.
    pub fn signer(self: *AccountRoot) manifest.Signer {
        return self.delegate.signer();
    }

    /// Builds a provisioner bound to this account root: it enrolls agents into the same registry and endorses
    /// their manifests with the account's keystore key. The returned provisioner borrows the signer that
    /// points into this root, so the root must outlive it.
    pub fn provisioner(self: *AccountRoot, gpa: std.mem.Allocator) issuance.Provisioner {
        return .init(gpa, self.registry, self.account, self.public_key, self.signer(), self.policy_domain);
    }

    /// The public half of the identity key the account mints and custodies for a local agent it runs, named
    /// by the agent's role, creating it on first request. A local agent's manifest binds a real key this way
    /// rather than a placeholder, and the account holds the key so removing the agent can destroy it.
    pub fn agentIdentity(self: *AccountRoot, role: []const u8) Error![manifest.public_key_bytes]u8 {
        return self.keystore.publicKey(self.account, role) catch |err| switch (err) {
            error.UnknownKey => {
                try self.keystore.create(self.account, role, .session_binding, .{});
                return self.keystore.publicKey(self.account, role);
            },
            else => err,
        };
    }

    /// Provisions the account's first-run roster through a provisioner built from this root: each default
    /// agent gets a real identity key and a manifest the account endorses with its key. Returns how many were
    /// provisioned. Idempotent per role: a re-driven bring-up reuses each agent's identity and neither mints a
    /// second key nor re-endorses, because the provisioner keys on the idempotency key threaded here.
    pub fn provisionDefaults(
        self: *AccountRoot,
        prov: *issuance.Provisioner,
        expires_at: time.Timestamp,
    ) Error!usize {
        var provisioned: usize = 0;
        for (roster.default_agents, 0..) |default_agent, index| {
            const agent_key = try self.agentIdentity(default_agent.role);
            const outcome = try prov.provision(.{
                .issuer = .human,
                .kind = default_agent.kind,
                .role = default_agent.role,
                .envelope = default_agent.envelope,
                .policy = self.policy,
                .expires_at = expires_at,
                .agent_public_key = agent_key,
                .idempotency_key = @intCast(index + 1),
            });
            switch (outcome) {
                .provisioned => provisioned += 1,
                // A default envelope is conservative and admissible under any account policy; a refusal here
                // would mean a misconfigured policy, and it is surfaced by the shortfall in the count rather
                // than by a silent standing identity.
                .refused => {},
            }
        }
        return provisioned;
    }
};

// --- Tests ---

const testing = std.testing;

const Fixture = struct {
    software: secure_element.SoftwareElement,
    keystore: keystore_mod.Keystore,
    ids: identity.Source,
    clock: time.ManualClock,
    registry: principal.Registry,
    root: AccountRoot,

    fn init(self: *Fixture, policy: creation.PolicyDomain) !void {
        self.software = .{};
        self.keystore = .init(self.software.element());
        self.ids = .initDeterministic(1);
        self.clock = .init(.fromSeconds(1_000));
        self.registry = .init(testing.allocator, &self.ids, self.clock.clock());
        try self.root.establish(&self.keystore, &self.registry, "owner", "personal", policy, .{});
    }

    fn deinit(self: *Fixture) void {
        self.registry.deinit();
    }

    fn agentKey(seed: u8) [manifest.public_key_bytes]u8 {
        const pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(seed)) catch unreachable;
        return pair.public_key.toBytes();
    }

    fn request(
        self: *Fixture,
        role: []const u8,
        envelope: provisioning.AuthorityEnvelope,
        policy: creation.PolicyDomain,
        key_seed: u8,
        idem: u128,
    ) issuance.Request {
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

test "a provisioned agent has a manifest the account endorses with its keystore key" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    // The account's public key is the endorsement key's public half, read from the element.
    try testing.expectEqualSlices(
        u8,
        &(try fixture.keystore.publicKey(fixture.root.account, endorsement_key_name)),
        &fixture.root.public_key,
    );

    var prov = fixture.root.provisioner(testing.allocator);
    defer prov.deinit();

    const agent = switch (try prov.provision(fixture.request("Calendar agent", .{}, .{}, 10, 0x1))) {
        .provisioned => |id| id,
        .refused => return error.TestUnexpectedResult,
    };

    // The manifest verifies against the account key — the endorsement was produced by the keystore-held
    // key, not by the provisioning path, which never saw it.
    try testing.expect(prov.endorsementValid(agent));
    try testing.expectEqual(issuance.Decision{ .granted = .silent }, prov.enforce(agent, "calendar.read"));
    try testing.expectEqual(issuance.Decision{ .denied = .no_grant }, prov.enforce(agent, "calendar.commit"));
}

test "a widened re-provision is a new manifest the account must freshly endorse" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    var prov = fixture.root.provisioner(testing.allocator);
    defer prov.deinit();

    const agent = (try prov.provision(fixture.request("Calendar agent", .{}, .{}, 11, 0x2))).provisioned;
    try testing.expectEqual(issuance.Decision{ .denied = .no_grant }, prov.enforce(agent, "calendar.commit"));

    // Widen under a policy that now grants consequential authority: held pending fresh acceptance, and until
    // then the agent keeps only its old authority.
    const open: creation.PolicyDomain = .{ .consequential_granted = true };
    const wider = fixture.request("Calendar agent", .{ .consequential = true, .approval = .hold }, open, 11, 0x3);
    try testing.expectEqual(issuance.Reprovision.awaiting_acceptance, try prov.reprovision(agent, wider));
    try testing.expectEqual(issuance.Decision{ .denied = .no_grant }, prov.enforce(agent, "calendar.commit"));

    // Fresh acceptance re-endorses with the account key and promotes the widened manifest.
    try testing.expect(try prov.accept(agent));
    try testing.expectEqual(issuance.Decision{ .granted = .hold }, prov.enforce(agent, "calendar.commit"));
    try testing.expect(prov.endorsementValid(agent));
}

test "an envelope beyond the account policy is refused before the account endorses anything" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    var prov = fixture.root.provisioner(testing.allocator);
    defer prov.deinit();

    const outcome = try prov.provision(fixture.request("Files agent", .{ .consequential = true }, .{}, 12, 0x4));
    try testing.expectEqual(issuance.Outcome{ .refused = .consequential_beyond_account }, outcome);

    // Nothing was minted or endorsed: no manifest, and the registry holds only the account's human.
    try testing.expectEqual(@as(u32, 0), prov.accepted.count());
    try testing.expectEqual(@as(usize, 1), fixture.registry.count());
}

test "establishing an account brings up its first-run roster, each agent endorsed by the account key" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    var prov = fixture.root.provisioner(testing.allocator);
    defer prov.deinit();

    const provisioned = try fixture.root.provisionDefaults(&prov, .fromSeconds(10_000));
    try testing.expectEqual(roster.default_agents.len, provisioned);
    try testing.expectEqual(@as(u32, roster.default_agents.len), prov.accepted.count());
    // Every provisioned agent is a real principal in the registry alongside the account's human.
    try testing.expectEqual(roster.default_agents.len + 1, fixture.registry.count());

    // Every agent's manifest verifies against the account key.
    var ids = prov.accepted.keyIterator();
    while (ids.next()) |id| {
        try testing.expect(prov.endorsementValid(.{ .value = id.* }));
    }
}

test "the roster bring-up is idempotent: a re-driven establish mints and endorses nothing new" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    var prov = fixture.root.provisioner(testing.allocator);
    defer prov.deinit();

    _ = try fixture.root.provisionDefaults(&prov, .fromSeconds(10_000));
    const before = fixture.registry.count();
    // Re-drive the whole bring-up: same identity keys, same idempotency keys, so nothing new is enrolled.
    const again = try fixture.root.provisionDefaults(&prov, .fromSeconds(10_000));
    try testing.expectEqual(roster.default_agents.len, again);
    try testing.expectEqual(before, fixture.registry.count());
    try testing.expectEqual(@as(u32, roster.default_agents.len), prov.accepted.count());
}

test "establishing an account root unwinds cleanly when the endorsement key cannot be minted" {
    var software: secure_element.SoftwareElement = .{};
    // A key created before establish exhausts the element by name would still leave room; instead make the
    // element unavailable so the key cannot be minted at all, and assert the human enrollment is unwound.
    var keystore: keystore_mod.Keystore = .init(software.element());
    var ids: identity.Source = .initDeterministic(1);
    var clock: time.ManualClock = .init(.fromSeconds(1_000));
    var registry: principal.Registry = .init(testing.allocator, &ids, clock.clock());
    defer registry.deinit();

    software.unavailable = true;
    var root: AccountRoot = undefined;
    try testing.expectError(error.Unavailable, root.establish(&keystore, &registry, "owner", "personal", .{}, .{}));

    // The human enrolled before the key failed was revoked, so no usable account root stands: its principal
    // fails closed on the next operation.
    try testing.expectEqual(@as(usize, 1), registry.count());
    var entries = registry.entries.valueIterator();
    const human = entries.next().?;
    try testing.expectEqual(principal.Status.revoked, human.status);
}
