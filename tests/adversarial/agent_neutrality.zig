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

const capability = core.capability;
const principal = core.principal;
const identity = core.identity;
const time = core.time;

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
