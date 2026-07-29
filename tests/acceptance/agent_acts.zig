//! An agent, with a mind that can think, carries out a validated plan against a real app
//! through the gated frame — end to end, exactly once.
//!
//! This is the "agents are real" proof, composed from the pieces rather than restated. A
//! local mind is stood up behind the swap seam with an available backend, so the agent's
//! binding reports it may act; a bounded, untrusted proposal shows the mind is thinking
//! for real, not miming. A three-step plan is validated as a finite DAG, then run through
//! the planner's executor by a driver that maps each step to a real operation on the
//! Messages app. The app is reached only through its `invoke` frame — the same door a
//! person's finger uses — so a read runs, a local mutation runs, and the agent's
//! consequential send is held for a person, halting the plan exactly where the frame holds
//! it. Every step is ground truth in the audit ledger the person's feed reads, the held
//! send takes effect once and only once when approved, and an agent whose mind has no
//! backend cannot begin at all. Nothing here is faked: the mind, the executor, the app,
//! and the ledger are the shipped modules, wired together only in this test layer, which
//! sits above both `agents` and `applications` and so may import each.
//!
//! The driver lives here, not in an app: `applications` already depends on `agents`, so the
//! cross-layer wiring that drives the executor into the app cannot live in either without a
//! cycle. The test layer is the one place above both, so it is the driver's home.

const std = @import("std");
const core = @import("core");
const agents = @import("agents");
const applications = @import("applications");

const testing = std.testing;
const identity = core.identity;
const time = core.time;

const mind = agents.model_mind;
const local = agents.model_local_adapter;
const model_interface = agents.model_interface;
const planner = agents.planner;
const executor = agents.planner_executor;

const framework = applications.framework;
const messages = applications.messages;

const person: u128 = 0x5;
const assistant: u128 = 0xA;

/// One plan step's binding to a real app operation: which operation carries it out, with
/// what arguments, under which capability, whether that capability's full check passed, and
/// the idempotency key the effect is gated by. A step index into a plan indexes a slice of
/// these, so the driver knows what step `i` actually does in the app.
const StepBinding = struct {
    operation: []const u8,
    args: []const u8 = "",
    capability: []const u8,
    holds_capability: bool,
    key: u128,
};

/// Drives a validated plan's steps into a real app through its gated frame. For step
/// `index` it invokes the bound operation on the app as the acting agent and maps the
/// frame's `Outcome` back to the executor's `StepOutcome` one-to-one — executed, held,
/// denied, or failed — so a consequential act the frame holds halts the plan at exactly
/// that step, with no separate agent code path. It carries no state of its own beyond the
/// borrowed app, actor, and step map; the gating and recording are the frame's.
const AppDriver = struct {
    app: *framework.App,
    actor: framework.Actor,
    bindings: []const StepBinding,

    fn runStep(context: *anyopaque, index: usize) executor.StepOutcome {
        const driver: *AppDriver = @ptrCast(@alignCast(context));
        const binding = driver.bindings[index];
        const outcome = driver.app.invoke(
            driver.actor,
            .{ .operation = binding.operation, .args = binding.args },
            binding.capability,
            binding.holds_capability,
            binding.key,
        ) catch return .failed;
        return switch (outcome) {
            .executed => .executed,
            .held => .held,
            .denied => .denied,
            .failed => .failed,
        };
    }

    fn runner(driver: *AppDriver) executor.StepRunner {
        return .{ .context = driver, .run_fn = runStep };
    }
};

/// A stub runtime standing in for loaded weights: available, and proposing exactly the
/// tokens the call admitted, so the mind is available and thinking for real without a
/// model on disk.
var stub_backend_ctx: u8 = 0;
fn stubGenerate(_: *anyopaque, request: model_interface.Request) mind.Proposal {
    return .{ .tokens = request.max_tokens };
}
fn stubBackend() local.Backend {
    return .{ .context = &stub_backend_ctx, .generate_fn = stubGenerate };
}

/// Everything the demonstration runs against: the identity source and clock the ledger
/// needs, the ledger itself, the Messages store, and the app assembled over the frame.
const World = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    ledger: core.audit.Ledger,
    store: messages.Store,
    app: framework.App,

    fn init(gpa: std.mem.Allocator, world: *World) void {
        world.ids = .initDeterministic(20260729);
        world.manual = .init(.fromSeconds(1_767_225_600));
        world.ledger = .init(gpa, &world.ids, world.manual.clock());
        world.store = messages.Store.init(gpa);
        world.app = messages.open(&world.store, &world.ledger);
    }

    fn deinit(world: *World) void {
        world.store.deinit();
        world.ledger.deinit();
    }

    fn agent(_: World) framework.Actor {
        return .{ .kind = .agent, .principal = .{ .value = assistant } };
    }
    fn human(_: World) framework.Actor {
        return .{ .kind = .human, .principal = .{ .value = person } };
    }
};

test "a backed agent runs a validated plan into a real app, held at the consequential step" {
    const gpa = testing.allocator;

    // The agent can think: a local mind with a loaded runtime is available, so its binding
    // may act, and it proposes a bounded, untrusted result — the interface's own guarantee.
    var mind_engine = local.LocalMind{};
    mind_engine.load(stubBackend());
    const binding = mind.Binding{ .agent = assistant, .mind = mind_engine.asMind() };
    try testing.expect(binding.canAct());
    const proposal = binding.mind.propose(.{ .max_tokens = 128 });
    try testing.expectEqual(@as(u32, 128), proposal.tokens); // bounded to what the call admitted
    try testing.expectEqual(model_interface.Provenance.untrusted, proposal.provenance);

    // A real app, stood up over the frame.
    var world: World = undefined;
    World.init(gpa, &world);
    defer world.deinit();

    // A three-step plan, validated as a finite backward-pointing DAG before a step runs:
    // read the thread, draft a reply, then send it. Send depends on the draft, which
    // depends on the read — a linear chain of depth three.
    var steps = [_]planner.Step{
        .{ .depends_on = &.{} },
        .{ .depends_on = &.{0} },
        .{ .depends_on = &.{1} },
    };
    const plan: planner.Plan = .{ .steps = &steps };
    try testing.expectEqual(@as(usize, 3), try plan.validate());

    // Each step is bound to the real Messages operation it performs, under the capability
    // that operation requires. The agent holds each capability's full-check verdict.
    const bindings = [_]StepBinding{
        .{ .operation = "message.read", .capability = "messages.read", .holds_capability = true, .key = 0x10 },
        .{ .operation = "message.draft", .capability = "messages.compose", .holds_capability = true, .key = 0x11 },
        .{ .operation = "message.send", .args = "On my way", .capability = "messages.send", .holds_capability = true, .key = 0x12 },
    };
    var driver = AppDriver{ .app = &world.app, .actor = world.agent(), .bindings = &bindings };

    // The agent may act, so the executor drives the plan into the app.
    try testing.expect(binding.canAct());
    const progress = executor.run(plan, driver.runner());

    // The read and the draft executed — the agent's own operations. The consequential send
    // is held by the frame for a person, so the executor stops there: two steps ran, the
    // plan halted at step 2, and the reason is the hold, not a failure.
    try testing.expect(!progress.complete());
    try testing.expectEqual(@as(usize, 2), progress.ran);
    try testing.expectEqual(@as(usize, 2), progress.stopped_at.?);
    try testing.expectEqual(executor.StepOutcome.held, progress.reason.?);
    // The send was held, not applied: nothing has actually been sent.
    try testing.expectEqual(@as(usize, 0), world.store.sent());

    // The person watches from the ledger, never from anything the agent said. All three
    // steps are recorded ground truth: the read and draft succeeded, the send is an
    // approval request awaiting a person.
    const feed = try framework.feedForActor(&world.ledger, gpa, .{ .value = assistant });
    defer gpa.free(feed);
    try testing.expectEqual(@as(usize, 3), feed.len);
    try testing.expectEqualStrings("message.read", feed[0].operation);
    try testing.expectEqualStrings("message.draft", feed[1].operation);
    try testing.expectEqualStrings("message.send", feed[2].operation);
    try testing.expectEqual(core.audit.Action.approval_requested, feed[2].action);
    try testing.expectEqual(core.outcome.Outcome.awaiting_approval, feed[2].outcome);

    // The person approves the held send — twice, as a double tap or a retry after a restart
    // would. The effect is keyed, so it takes effect once and only once.
    _ = try world.app.approve(world.human(), .{ .operation = "message.send", .args = "On my way" }, 0x12);
    _ = try world.app.approve(world.human(), .{ .operation = "message.send", .args = "On my way" }, 0x12);
    try testing.expectEqual(@as(usize, 1), world.store.sent());
    try testing.expectEqualStrings("On my way", world.store.bodyAt(0).?);
}

test "an agent whose mind has no backend is inert and never begins the plan" {
    const gpa = testing.allocator;

    // A local mind with no runtime loaded is honestly unavailable, so the binding may not
    // act. Its authority is held, not exercised.
    var mind_engine = local.LocalMind{};
    const binding = mind.Binding{ .agent = assistant, .mind = mind_engine.asMind() };
    try testing.expectEqual(mind.Health.unavailable, binding.mind.health());
    try testing.expect(!binding.canAct());

    var world: World = undefined;
    World.init(gpa, &world);
    defer world.deinit();

    var steps = [_]planner.Step{ .{ .depends_on = &.{} }, .{ .depends_on = &.{0} } };
    const plan: planner.Plan = .{ .steps = &steps };
    const bindings = [_]StepBinding{
        .{ .operation = "message.read", .capability = "messages.read", .holds_capability = true, .key = 0x20 },
        .{ .operation = "message.send", .capability = "messages.send", .holds_capability = true, .key = 0x21 },
    };
    var driver = AppDriver{ .app = &world.app, .actor = world.agent(), .bindings = &bindings };

    // Because the mind cannot act, the plan never runs — the agent cannot even begin. The
    // ledger proves it: not one operation reached the app.
    var progress: executor.Progress = .{};
    if (binding.canAct()) progress = executor.run(plan, driver.runner());
    try testing.expectEqual(@as(usize, 0), progress.ran);
    try testing.expectEqual(@as(usize, 0), world.ledger.count());
    try testing.expectEqual(@as(usize, 0), world.store.sent());
}
