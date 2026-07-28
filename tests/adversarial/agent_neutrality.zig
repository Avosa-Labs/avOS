//! Agent neutrality: no agent is special at the enforcement point.
//!
//! The platform's central claim is that its governance applies to every agent equally — a cloud
//! model, a local model, an embodied device agent — because there is exactly one enforcement point
//! (the capability service) and no agent-specific privilege path. The adapter that produced a plan
//! is metadata; it never reaches the authorization decision. This is the adversarial proof of that:
//! give several agent principals, standing for different minds, the identical grant and drive the
//! identical request, and assert the authorization outcome is identical for every one — the same
//! success, the same refusal for the same reason. If any agent ever got a different answer, the
//! "settings apply to all agents" claim would be false, and this would fail loudly.

const std = @import("std");
const core = @import("core");
const agents = @import("agents");

const capability = core.capability;
const principal = core.principal;
const identity = core.identity;
const time = core.time;
const audit = core.audit;
const mind_seam = agents.model_mind;
const model_interface = agents.model_interface;

// A minimal available mind for the swap test: it proposes bounded, untrusted output and reports
// itself healthy. Two contexts stand for two different minds behind the same contract.
var mind_ctx_a: u8 = 0;
var mind_ctx_b: u8 = 0;

fn stubPropose(_: *anyopaque, request: model_interface.Request) mind_seam.Proposal {
    return .{ .tokens = request.max_tokens };
}
fn stubHealthy(_: *anyopaque) mind_seam.Health {
    return .available;
}
fn stubMind(ctx: *u8) mind_seam.Mind {
    return .{ .context = ctx, .propose_fn = stubPropose, .health_fn = stubHealthy };
}

/// The enforcement world under test: a principal registry and the capability service over it, with
/// one human who issues grants to agents.
const World = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal.Registry,
    store: capability.Store,
    human: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, world: *World) !void {
        world.* = .{
            .ids = .initDeterministic(20260727),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .human = .none,
        };
        world.registry = .init(gpa, &world.ids, world.manual.clock());
        world.store = .init(gpa, &world.ids, world.manual.clock(), &world.registry);
        world.human = try world.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        });
    }

    fn deinit(world: *World) void {
        world.store.deinit();
        world.registry.deinit();
    }

    /// Enrols an agent principal standing for one mind behind the agent contract. The display name
    /// is the only thing that differs — the adapter (which model) is metadata, not authority.
    fn enrollAgent(world: *World, name: []const u8) !identity.PrincipalId {
        return world.registry.enroll(.{
            .kind = .agent,
            .display_name = name,
            .policy_domain = "local",
            .expires_at = .fromSeconds(100_000),
            .issuer = world.human,
        });
    }
};

fn readOnly() capability.OperationSet {
    var set: capability.OperationSet = .initEmpty();
    set.insert(.read);
    return set;
}

test "no agent is special: identical grant and request yield identical authorization, whatever the mind" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    try World.init(gpa, &world);
    defer world.deinit();

    // Four agent principals standing for four different minds behind one contract: a local model,
    // two remote providers, and an embodied device agent. They differ only in identity.
    const minds = [_][]const u8{ "local-model", "provider-a", "provider-b", "device-agent" };
    for (minds) |mind| {
        const agent = try world.enrollAgent(mind);
        const handle = try world.store.issue(.{
            .issuer = world.human,
            .holder = agent,
            .resource = .{ .kind = "calendar" },
            .operations = readOnly(),
        });

        // The granted read succeeds for every mind.
        _ = try world.store.check(handle, .{
            .holder = agent,
            .operation = .read,
            .resource = .{ .kind = "calendar" },
        });

        // The same out-of-grant write is refused for every mind, for the identical reason.
        try std.testing.expectError(error.Unauthorized, world.store.check(handle, .{
            .holder = agent,
            .operation = .write,
            .resource = .{ .kind = "calendar" },
        }));
        try std.testing.expectEqual(capability.Refusal.operation_not_granted, world.store.last_refusal.?);
    }
}

test "the model a use runs against never changes the authorization outcome" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    try World.init(gpa, &world);
    defer world.deinit();

    const agent = try world.enrollAgent("agent");
    const handle = try world.store.issue(.{
        .issuer = world.human,
        .holder = agent,
        .resource = .{ .kind = "calendar" },
        .operations = readOnly(),
    });

    // The same grant, exercised under different models (and none): the answer is the model-blind
    // one every time — the granted read passes, the out-of-grant write is refused identically.
    const models = [_]?[]const u8{ null, "local", "provider-a", "provider-b" };
    for (models) |model| {
        _ = try world.store.check(handle, .{
            .holder = agent,
            .operation = .read,
            .resource = .{ .kind = "calendar" },
            .model = model,
        });
        try std.testing.expectError(error.Unauthorized, world.store.check(handle, .{
            .holder = agent,
            .operation = .write,
            .resource = .{ .kind = "calendar" },
            .model = model,
        }));
        try std.testing.expectEqual(capability.Refusal.operation_not_granted, world.store.last_refusal.?);
    }
}

test "the ledger records one action as the same shape, whatever agent took it" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(20260727);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var ledger = audit.Ledger.init(gpa, &ids, manual.clock());
    defer ledger.deinit();

    // Two agents, identified differently, take the identical action.
    const record = audit.Record{
        .actor = .{ .value = 0xA },
        .action = .tool_invoked,
        .outcome = .succeeded,
        .target_kind = "calendar",
    };
    _ = try ledger.append(record);
    var other = record;
    other.actor = .{ .value = 0xB };
    _ = try ledger.append(other);

    const first = ledger.at(0).?;
    const second = ledger.at(1).?;

    // The recorded shape is identical — action, outcome, target kind, provenance, movement, and
    // refusal all match — so the activity feed a person reads cannot be coloured by which agent
    // acted. The ledger records who acted without letting that change what is recorded.
    try std.testing.expectEqual(first.action, second.action);
    try std.testing.expectEqual(first.outcome, second.outcome);
    try std.testing.expect(std.mem.eql(u8, first.target_kind, second.target_kind));
    try std.testing.expectEqual(first.provenance, second.provenance);
    try std.testing.expectEqual(first.data_movement, second.data_movement);
    try std.testing.expectEqual(first.refusal, second.refusal);
    // Only the actor differs.
    try std.testing.expect(!std.meta.eql(first.actor, second.actor));
}

test "an agent cannot use a grant issued to a different agent, whatever mind it runs" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    try World.init(gpa, &world);
    defer world.deinit();

    const owner = try world.enrollAgent("owner");
    const impostor = try world.enrollAgent("impostor");
    const handle = try world.store.issue(.{
        .issuer = world.human,
        .holder = owner,
        .resource = .{ .kind = "calendar" },
        .operations = readOnly(),
    });

    // The holder may use it; another agent presenting the same handle is refused — neutrality does
    // not mean fungibility. Authority is bound to the principal it was issued to.
    _ = try world.store.check(handle, .{ .holder = owner, .operation = .read, .resource = .{ .kind = "calendar" } });
    try std.testing.expectError(error.Unauthorized, world.store.check(handle, .{
        .holder = impostor,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
}

test "swapping a running agent's mind leaves its identity and authority unchanged" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    try World.init(gpa, &world);
    defer world.deinit();

    const agent = try world.enrollAgent("running-agent");
    const handle = try world.store.issue(.{
        .issuer = world.human,
        .holder = agent,
        .resource = .{ .kind = "calendar" },
        .operations = readOnly(),
    });

    // With its first mind, the granted read passes and an out-of-grant write is refused.
    _ = try world.store.check(handle, .{ .holder = agent, .operation = .read, .resource = .{ .kind = "calendar" } });
    try std.testing.expectError(error.Unauthorized, world.store.check(handle, .{
        .holder = agent,
        .operation = .write,
        .resource = .{ .kind = "calendar" },
    }));

    // The agent is bound to mind A; swap it to mind B mid-life. The binding's id stands for this
    // agent's identity, which the swap must preserve — a change of engine, not of actor.
    const before = mind_seam.Binding{ .agent = 0xA9E27, .mind = stubMind(&mind_ctx_a) };
    const after = mind_seam.swap(before, stubMind(&mind_ctx_b));
    try std.testing.expectEqual(before.agent, after.agent); // identity preserved
    try std.testing.expect(after.canAct()); // the swapped-in mind is available

    // After the swap, the SAME grant yields the SAME authorization: the capability service never saw
    // the mind, so changing the engine changed nothing about what the agent may do.
    _ = try world.store.check(handle, .{ .holder = agent, .operation = .read, .resource = .{ .kind = "calendar" } });
    try std.testing.expectError(error.Unauthorized, world.store.check(handle, .{
        .holder = agent,
        .operation = .write,
        .resource = .{ .kind = "calendar" },
    }));
}
