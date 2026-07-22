//! Session continuity acceptance.
//!
//! Holds continuity to what it must demonstrate: that the canonical task
//! continues across endpoints, that no external action occurs twice, that a
//! revoked endpoint loses access, and that the audit identifies both endpoint
//! principals.
//!
//! The transfer here is the one the canonical demonstration performs — a task
//! begun on one endpoint and resumed on another — driven through the same
//! interfaces a running system uses.

const std = @import("std");
const core = @import("core");
const session = @import("session");

const identity = core.identity;
const task_model = core.task;
const audit = core.audit;
const policy_model = core.policy;
const capability_model = core.capability;

const endpoint_model = session.endpoint;
const instance_model = session.instance;
const transport = session.transport;

/// The canonical demonstration's continuity step, with everything it needs.
const Continuity = struct {
    ids: identity.Source,
    manual: core.time.ManualClock,
    registry: core.principal.Registry,
    store: capability_model.Store,
    graph: task_model.Graph,
    ledger: audit.Ledger,
    centre: policy_model.Centre,
    endpoints: endpoint_model.Registry,
    instance: instance_model.Instance,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,
    phone: identity.PrincipalId,
    desktop: identity.PrincipalId,
    root: identity.TaskId,

    /// The effect the demonstration performs exactly once.
    const confirmation_key: u128 = 0x5ec0_0dad;

    fn init(gpa: std.mem.Allocator, continuity: *Continuity) !void {
        continuity.* = .{
            .ids = .initDeterministic(20260722),
            .manual = .init(.fromSeconds(1_767_225_600)),
            .registry = undefined,
            .store = undefined,
            .graph = undefined,
            .ledger = undefined,
            .centre = undefined,
            .endpoints = undefined,
            .instance = undefined,
            .human = .none,
            .agent = .none,
            .phone = .none,
            .desktop = .none,
            .root = .none,
        };
        const clock = continuity.manual.clock();
        continuity.registry = .init(gpa, &continuity.ids, clock);
        continuity.store = .init(gpa, &continuity.ids, clock, &continuity.registry);
        continuity.graph = .init(gpa, &continuity.ids, clock);
        continuity.ledger = .init(gpa, &continuity.ids, clock);
        continuity.centre = .init(gpa, &continuity.ids, clock, .strict);
        continuity.endpoints = .init(gpa, &continuity.ids, clock);

        continuity.human = try continuity.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        });
        continuity.agent = try continuity.registry.enroll(.{
            .kind = .agent,
            .display_name = "travel",
            .policy_domain = "local",
            .expires_at = .fromSeconds(1_767_300_000),
            .issuer = continuity.human,
        });

        continuity.phone = try continuity.endpoints.enrol(.{
            .human = continuity.human,
            .name = "Phone",
            .permissions = .full,
        });
        continuity.desktop = try continuity.endpoints.enrol(.{
            .human = continuity.human,
            .name = "Desktop",
            .permissions = .full,
        });

        continuity.instance = .init(
            gpa,
            clock,
            continuity.human,
            &continuity.endpoints,
            &continuity.ledger,
        );

        continuity.root = try continuity.graph.create(.{
            .owner = continuity.human,
            .requester = continuity.human,
            .purpose = "prepare for the scheduled event",
            .budget_bytes = 1 << 16,
        });
        try continuity.graph.transition(continuity.root, .runnable);
        try continuity.graph.transition(continuity.root, .running);
    }

    fn deinit(continuity: *Continuity) void {
        continuity.instance.deinit();
        continuity.endpoints.deinit();
        continuity.centre.deinit();
        continuity.ledger.deinit();
        continuity.graph.deinit();
        continuity.store.deinit();
        continuity.registry.deinit();
    }
};

test "the canonical task continues on a second endpoint without changing identity" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    try continuity.instance.present(continuity.phone);

    const owner_before = continuity.graph.get(continuity.root).?.owner;
    const state_before = continuity.graph.get(continuity.root).?.state;

    try continuity.instance.transferTo(continuity.desktop);

    // The endpoint changed. The principal, the task, and its state did not.
    try std.testing.expect(continuity.instance.presenting.eql(continuity.desktop));
    try std.testing.expect(continuity.instance.human.eql(continuity.human));
    try std.testing.expect(continuity.graph.get(continuity.root).?.owner.eql(owner_before));
    try std.testing.expectEqual(state_before, continuity.graph.get(continuity.root).?.state);
}

test "an approved action does not execute twice across a transfer" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    try continuity.instance.present(continuity.phone);

    // The human approves, and the phone performs the action.
    const approval = try continuity.centre.request(.{
        .requester = continuity.agent,
        .approver = continuity.human,
        .task = continuity.root,
        .operation = .send,
        .target_kind = "message",
        .summary = "send a confirmation of attendance to the venue",
    });
    try continuity.centre.decide(approval, continuity.human, .approved);
    _ = try continuity.centre.consume(approval, continuity.agent);

    try continuity.instance.claimEffect(
        Continuity.confirmation_key,
        "send a confirmation of attendance to the venue",
        continuity.phone,
    );
    try continuity.instance.settleEffect(Continuity.confirmation_key, .performed);

    // The session moves and the task resumes on the desktop.
    try continuity.instance.transferTo(continuity.desktop);

    // Neither the approval nor the effect may be repeated there.
    try std.testing.expectError(
        error.Conflict,
        continuity.centre.consume(approval, continuity.agent),
    );
    try std.testing.expectError(error.AlreadyPerformed, continuity.instance.claimEffect(
        Continuity.confirmation_key,
        "send a confirmation of attendance to the venue",
        continuity.desktop,
    ));

    try std.testing.expectEqual(@as(usize, 1), continuity.instance.effectCount());
}

test "an effect in flight when the session moves is not restarted" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    try continuity.instance.present(continuity.phone);

    // Claimed on the phone and still in flight when the session moves.
    try continuity.instance.claimEffect(
        Continuity.confirmation_key,
        "send a confirmation",
        continuity.phone,
    );
    try continuity.instance.transferTo(continuity.desktop);

    // Whether it ran is not yet known, so starting it again is refused.
    try std.testing.expectError(error.AlreadyPerformed, continuity.instance.claimEffect(
        Continuity.confirmation_key,
        "send a confirmation",
        continuity.desktop,
    ));
}

test "a revoked endpoint loses access to the session it was presenting" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    try continuity.instance.present(continuity.desktop);
    try continuity.instance.claimEffect(0x111, "an effect", continuity.desktop);

    try continuity.endpoints.revoke(continuity.desktop);

    try std.testing.expectError(
        error.EndpointNotPermitted,
        continuity.instance.claimEffect(0x222, "another effect", continuity.desktop),
    );
    try std.testing.expectError(
        error.EndpointNotPermitted,
        continuity.instance.transferTo(continuity.desktop),
    );

    // And receives no state of any category.
    for (std.enums.values(instance_model.StateCategory)) |category| {
        try std.testing.expect(!continuity.instance.maySynchronize(category, continuity.desktop));
    }
}

test "the audit identifies both endpoint principals" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    try continuity.instance.present(continuity.phone);
    try continuity.instance.transferTo(continuity.desktop);

    const from_phone = try continuity.ledger.eventsForActor(gpa, continuity.phone);
    defer gpa.free(from_phone);
    const from_desktop = try continuity.ledger.eventsForActor(gpa, continuity.desktop);
    defer gpa.free(from_desktop);

    try std.testing.expect(from_phone.len > 0);
    try std.testing.expect(from_desktop.len > 0);
    try std.testing.expect(continuity.ledger.verifySequence());

    // Both endpoints are named, so a reader can say which device the work
    // moved between rather than only that it moved.
    var saw_connection = false;
    for (from_desktop) |event| {
        if (event.action == .endpoint_connected) saw_connection = true;
    }
    try std.testing.expect(saw_connection);
}

test "state moving between endpoints is encrypted end to end" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    const phone_seed: [std.crypto.dh.X25519.seed_length]u8 = @splat(31);
    const desktop_seed: [std.crypto.dh.X25519.seed_length]u8 = @splat(32);
    const phone_pair = try transport.KeyPair.generateDeterministic(phone_seed);
    const desktop_pair = try transport.KeyPair.generateDeterministic(desktop_seed);

    var sending = try transport.Session.establish(
        phone_pair,
        desktop_pair.publicKey(),
        continuity.phone,
        continuity.desktop,
        .initiator,
    );
    defer sending.deinit();
    var receiving = try transport.Session.establish(
        desktop_pair,
        phone_pair.publicKey(),
        continuity.desktop,
        continuity.phone,
        .responder,
    );
    defer receiving.deinit();

    const state = "the task graph and its pending approval";
    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const record = try sending.seal(state, &sealed);

    // Anything carrying the record sees ciphertext.
    try std.testing.expect(std.mem.indexOf(u8, record.payload, "approval") == null);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, "task graph") == null);

    try std.testing.expectEqualStrings(state, try receiving.open(record, &opened));
}

test "a relay cannot replay session state back at the endpoint that sent it" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    const phone_seed: [std.crypto.dh.X25519.seed_length]u8 = @splat(41);
    const desktop_seed: [std.crypto.dh.X25519.seed_length]u8 = @splat(42);
    const phone_pair = try transport.KeyPair.generateDeterministic(phone_seed);
    const desktop_pair = try transport.KeyPair.generateDeterministic(desktop_seed);

    var sending = try transport.Session.establish(
        phone_pair,
        desktop_pair.publicKey(),
        continuity.phone,
        continuity.desktop,
        .initiator,
    );
    defer sending.deinit();
    var receiving = try transport.Session.establish(
        desktop_pair,
        phone_pair.publicKey(),
        continuity.desktop,
        continuity.phone,
        .responder,
    );
    defer receiving.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try sending.seal("apply the transfer", &sealed);
    _ = try receiving.open(record, &opened);

    // Delivered once and only once, and never back at its sender.
    try std.testing.expectError(error.ReplayDetected, receiving.open(record, &opened));
    try std.testing.expectError(error.IntegrityFailure, sending.open(record, &opened));
}

test "the instance survives every endpoint being revoked" {
    const gpa = std.testing.allocator;
    var continuity: Continuity = undefined;
    try Continuity.init(gpa, &continuity);
    defer continuity.deinit();

    try continuity.instance.present(continuity.phone);
    try continuity.instance.claimEffect(0x333, "an effect", continuity.phone);

    try continuity.endpoints.revoke(continuity.phone);
    try continuity.endpoints.revoke(continuity.desktop);

    // Losing every endpoint does not destroy the environment or what it knows.
    try std.testing.expect(continuity.instance.human.eql(continuity.human));
    try std.testing.expectEqual(@as(usize, 1), continuity.instance.effectCount());
    try std.testing.expect(continuity.graph.get(continuity.root) != null);
}
