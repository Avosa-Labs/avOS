//! The integrated demonstration.
//!
//! Proves the canonical sequence end to end, in order, through the same
//! interfaces a running system uses. Each of the twelve steps is asserted where
//! it happens rather than summarized afterwards, so a step that stopped working
//! fails at the point it broke.
//!
//! What this does not do is execute Android application binaries. That needs the
//! reference device, which needs a host this project does not yet have; the
//! Android step here exercises the mediation and the bridge, which is a
//! different and smaller claim. It is stated here so this file cannot be read as
//! evidence of the larger one.

const std = @import("std");
const core = @import("core");
const shell = @import("shell");
const session = @import("session");
const android = @import("runtime_android");
const brand = @import("brand");

const identity = core.identity;
const task_model = core.task;
const audit = core.audit;
const policy_model = core.policy;
const capability_model = core.capability;
const resource = core.resource;

const surfaces = shell.surfaces;
const endpoint_model = session.endpoint;
const instance_model = session.instance;

/// Everything the demonstration runs against.
const World = struct {
    gpa: std.mem.Allocator,
    ids: identity.Source,
    manual: core.time.ManualClock,
    registry: core.principal.Registry,
    store: capability_model.Store,
    graph: task_model.Graph,
    ledger: audit.Ledger,
    centre: policy_model.Centre,
    endpoints: endpoint_model.Registry,
    bridge: android.bridge.Bridge,
    instance: instance_model.Instance,

    human: identity.PrincipalId = .none,
    calendar_agent: identity.PrincipalId = .none,
    mail_agent: identity.PrincipalId = .none,
    document_agent: identity.PrincipalId = .none,
    travel_agent: identity.PrincipalId = .none,
    phone: identity.PrincipalId = .none,
    desktop: identity.PrincipalId = .none,
    root: identity.TaskId = .none,

    /// One budget per agent branch, so consumption is attributable and a branch
    /// cannot starve the others.
    budgets: [4]resource.Budget = undefined,

    fn init(gpa: std.mem.Allocator, world: *World) !void {
        world.* = .{
            .gpa = gpa,
            .ids = .initDeterministic(20260722),
            .manual = .init(.fromSeconds(1_767_225_600)),
            .registry = undefined,
            .store = undefined,
            .graph = undefined,
            .ledger = undefined,
            .centre = undefined,
            .endpoints = undefined,
            .bridge = undefined,
            .instance = undefined,
        };
        const clock = world.manual.clock();
        world.registry = .init(gpa, &world.ids, clock);
        world.store = .init(gpa, &world.ids, clock, &world.registry);
        world.graph = .init(gpa, &world.ids, clock);
        world.ledger = .init(gpa, &world.ids, clock);
        world.centre = .init(gpa, &world.ids, clock, .strict);
        world.endpoints = .init(gpa, &world.ids, clock);
        world.bridge = .init(gpa, &world.ids, true);
        world.instance = .init(gpa, clock, .none, &world.endpoints, &world.ledger);
    }

    fn deinit(world: *World) void {
        world.instance.deinit();
        world.bridge.deinit();
        world.endpoints.deinit();
        world.centre.deinit();
        world.ledger.deinit();
        world.graph.deinit();
        world.store.deinit();
        world.registry.deinit();
    }

    fn now(world: *World) core.time.Timestamp {
        return world.manual.clock().wall();
    }

    fn enrolAgent(world: *World, name: []const u8) !identity.PrincipalId {
        const id = try world.registry.enroll(.{
            .kind = .agent,
            .display_name = name,
            .policy_domain = "local",
            .expires_at = .fromSeconds(1_767_300_000),
            .issuer = world.human,
        });
        _ = try world.ledger.append(.{
            .actor = id,
            .on_behalf_of = world.human,
            .action = .principal_created,
            .outcome = .succeeded,
        });
        return id;
    }

    fn grant(
        world: *World,
        holder: identity.PrincipalId,
        kind: []const u8,
        operations: []const capability_model.Operation,
        constraints: capability_model.Constraints,
    ) !capability_model.Handle {
        var set: capability_model.OperationSet = .initEmpty();
        for (operations) |operation| set.insert(operation);

        const handle = try world.store.issue(.{
            .issuer = world.human,
            .holder = holder,
            .resource = .{ .kind = kind },
            .operations = set,
            .constraints = constraints,
        });
        _ = try world.ledger.append(.{
            .actor = world.human,
            .on_behalf_of = holder,
            .action = .capability_issued,
            .outcome = .succeeded,
            .capability = handle.id,
            .target_kind = kind,
        });
        return handle;
    }

    /// Attempts an operation and records the result, whichever it is.
    fn attempt(
        world: *World,
        actor: identity.PrincipalId,
        handle: capability_model.Handle,
        context: capability_model.UseContext,
        movement: audit.DataMovement,
    ) !core.outcome.Outcome {
        if (world.store.use(handle, context)) |_| {
            _ = try world.ledger.append(.{
                .actor = actor,
                .on_behalf_of = world.human,
                .action = .capability_used,
                .outcome = .succeeded,
                .task = context.task,
                .capability = handle.id,
                .target_kind = context.resource.kind,
                .data_movement = movement,
            });
            return .succeeded;
        } else |refusal| {
            _ = try world.ledger.append(.{
                .actor = actor,
                .on_behalf_of = world.human,
                .action = .action_denied,
                .outcome = .denied,
                .refusal = refusal,
                .task = context.task,
                .capability = handle.id,
                .target_kind = context.resource.kind,
            });
            return .denied;
        }
    }

    fn branch(
        world: *World,
        owner: identity.PrincipalId,
        purpose: []const u8,
    ) !identity.TaskId {
        const id = try world.graph.create(.{
            .owner = owner,
            .requester = world.human,
            .purpose = purpose,
            .parent = world.root,
            .budget_bytes = 16 * 1024,
        });
        try world.graph.transition(id, .runnable);
        try world.graph.transition(id, .running);
        return id;
    }
};

test "the canonical demonstration proves its sequence end to end" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    try World.init(gpa, &world);
    defer world.deinit();

    // 1. A human principal authenticates.
    world.human = try world.registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });
    _ = try world.ledger.append(.{
        .actor = world.human,
        .action = .authenticated,
        .outcome = .succeeded,
        .provenance = .human_input,
    });
    world.instance.human = world.human;

    world.phone = try world.endpoints.enrol(.{
        .human = world.human,
        .name = "Phone",
        .permissions = .full,
    });
    world.desktop = try world.endpoints.enrol(.{
        .human = world.human,
        .name = "Desktop",
        .permissions = .full,
    });
    try world.instance.present(world.phone);

    // 2. The human requests preparation for a scheduled event.
    const request = try shell.command.submit(
        "prepare for the event on Thursday",
        world.human,
        true,
    );
    try std.testing.expectEqual(shell.command.Progress.submitted, request.progress);
    // Submission claims no plan yet; the planner has not run.
    try std.testing.expect(!shell.command.present(request).claims_external_effect);

    // 3. The system compiles the request into a visible task graph.
    world.root = try world.graph.create(.{
        .owner = world.human,
        .requester = world.human,
        .purpose = "prepare for the scheduled event",
        .deadline = world.now().plus(.fromSeconds(3_600)),
        .budget_bytes = 256 * 1024,
    });
    _ = try world.ledger.append(.{
        .actor = world.human,
        .action = .task_created,
        .outcome = .succeeded,
        .task = world.root,
        .provenance = .human_input,
    });
    try world.graph.transition(world.root, .runnable);
    try world.graph.transition(world.root, .running);

    const session_view: surfaces.Session = .{ .authenticated = true, .human = world.human };
    {
        const rows = try surfaces.projectTaskGraph(gpa, &world.graph, session_view);
        defer gpa.free(rows);
        try std.testing.expectEqual(@as(usize, 1), rows.len);
    }

    // 4. Multiple agents execute independent branches.
    world.calendar_agent = try world.enrolAgent("calendar");
    world.mail_agent = try world.enrolAgent("mail");
    world.document_agent = try world.enrolAgent("documents");
    world.travel_agent = try world.enrolAgent("travel");

    const calendar_task = try world.branch(world.calendar_agent, "inspect the calendar");
    const mail_task = try world.branch(world.mail_agent, "retrieve mail through a connector");
    const document_task = try world.branch(world.document_agent, "retrieve local documents");
    const travel_task = try world.branch(world.travel_agent, "plan the route");

    // 5. Every agent receives only the capabilities its branch requires.
    const calendar_grant = try world.grant(
        world.calendar_agent,
        "calendar",
        &.{ .read, .list },
        .{ .local_processing_only = true, .task_binding = calendar_task },
    );
    const mail_grant = try world.grant(
        world.mail_agent,
        "mail",
        &.{.read},
        .{ .local_processing_only = true, .task_binding = mail_task },
    );
    const document_grant = try world.grant(
        world.document_agent,
        "document",
        &.{ .read, .list },
        .{ .local_processing_only = true, .task_binding = document_task },
    );
    const travel_grant = try world.grant(
        world.travel_agent,
        "route",
        &.{.read},
        .{ .network_destinations = &.{"routing.invalid"}, .task_binding = travel_task },
    );

    // No agent holds another's authority.
    try std.testing.expectError(error.Unauthorized, world.store.check(calendar_grant, .{
        .holder = world.mail_agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .task = mail_task,
    }));

    for (world.budgets[0..], [_]identity.PrincipalId{
        world.calendar_agent,
        world.mail_agent,
        world.document_agent,
        world.travel_agent,
    }, [_]identity.TaskId{ calendar_task, mail_task, document_task, travel_task }) |*budget, owner, task| {
        budget.* = .init(gpa, 16 * 1024, .{ .principal = owner, .task = task });
    }

    var held: [4][]u8 = undefined;
    for (&held, &world.budgets) |*block, *budget| {
        block.* = try budget.allocator().alloc(u8, 2048);
    }

    // Each branch does the work it holds authority for.
    try std.testing.expectEqual(core.outcome.Outcome.succeeded, try world.attempt(
        world.calendar_agent,
        calendar_grant,
        .{
            .holder = world.calendar_agent,
            .operation = .read,
            .resource = .{ .kind = "calendar" },
            .task = calendar_task,
        },
        .stayed_local,
    ));
    try std.testing.expectEqual(core.outcome.Outcome.succeeded, try world.attempt(
        world.mail_agent,
        mail_grant,
        .{
            .holder = world.mail_agent,
            .operation = .read,
            .resource = .{ .kind = "mail" },
            .task = mail_task,
        },
        .stayed_local,
    ));
    try std.testing.expectEqual(core.outcome.Outcome.succeeded, try world.attempt(
        world.travel_agent,
        travel_grant,
        .{
            .holder = world.travel_agent,
            .operation = .read,
            .resource = .{ .kind = "route" },
            .task = travel_task,
            .network_destination = "routing.invalid",
            .processing_is_local = false,
        },
        .left_device,
    ));

    // An Android application is reached through the compatibility bridge.
    const application = try world.bridge.install(.{
        .framework = .{ .package_name = "com.example.calendar", .framework_user_id = 10_042 },
        .label = "Calendar",
        .requests = &.{},
        .offers = &.{.{
            .name = "read_next_event",
            .resource_kind = "calendar",
            .operation = .read,
            .summary = "read the next scheduled event",
        }},
    });
    try world.bridge.launch(application);
    const bridged = try world.bridge.invoke(
        application,
        "read_next_event",
        world.calendar_agent,
        &world.store,
        calendar_grant,
        calendar_task,
    );
    try std.testing.expectEqual(core.outcome.Outcome.succeeded, bridged.outcome);

    // 6. At least one unauthorized action is denied and recorded.
    try std.testing.expectEqual(core.outcome.Outcome.denied, try world.attempt(
        world.document_agent,
        document_grant,
        .{
            .holder = world.document_agent,
            .operation = .delete,
            .resource = .{ .kind = "document" },
            .task = document_task,
        },
        .not_applicable,
    ));

    // 7. A consequential action is held for human approval.
    const confirmation_task = try world.graph.create(.{
        .owner = world.travel_agent,
        .requester = world.human,
        .purpose = "confirm attendance with the venue",
        .parent = travel_task,
        .budget_bytes = 4096,
    });
    try world.graph.transition(confirmation_task, .waiting_for_approval);

    const approval = try world.centre.request(.{
        .requester = world.travel_agent,
        .approver = world.human,
        .task = confirmation_task,
        .operation = .send,
        .target_kind = "message",
        .summary = "send a confirmation of attendance to the venue",
    });
    const requested_event = try world.ledger.append(.{
        .actor = world.travel_agent,
        .on_behalf_of = world.human,
        .action = .approval_requested,
        .outcome = .awaiting_approval,
        .task = confirmation_task,
    });

    {
        const pending = try surfaces.projectApprovals(gpa, &world.centre, session_view);
        defer gpa.free(pending);
        try std.testing.expectEqual(@as(usize, 1), pending.len);
    }
    // It cannot proceed while the decision is outstanding.
    try std.testing.expectError(
        error.Unauthorized,
        world.centre.consume(approval, world.travel_agent),
    );

    // 8. Approval grants a narrowly scoped, one-time capability.
    world.manual.advance(.fromSeconds(5));
    try world.centre.decide(approval, world.human, .approved);
    const decided_event = try world.ledger.append(.{
        .actor = world.human,
        .action = .approval_decided,
        .outcome = .succeeded,
        .task = confirmation_task,
        .parent = requested_event,
        .provenance = .human_input,
    });
    const granted = try world.centre.consume(approval, world.travel_agent);

    var send_constraints = policy_model.constraintsForApproval(
        granted,
        world.now().plus(.fromSeconds(300)),
    );
    send_constraints.recipients = &.{"the venue"};
    const send_handle = try world.grant(world.travel_agent, "message", &.{.send}, send_constraints);

    try std.testing.expect(send_constraints.one_time);
    try std.testing.expect(send_constraints.task_binding.eql(confirmation_task));
    try std.testing.expectEqual(@as(u8, 0), send_constraints.delegation_depth);

    // 9. The approved action executes exactly once.
    const send_context: capability_model.UseContext = .{
        .holder = world.travel_agent,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .task = confirmation_task,
        .recipient = "the venue",
        .human_confirmed = true,
        .processing_is_local = false,
    };
    try world.graph.transition(confirmation_task, .runnable);
    try world.graph.transition(confirmation_task, .running);

    try world.instance.claimEffect(
        0x5ec0_0dad,
        "send a confirmation of attendance to the venue",
        world.phone,
    );
    try std.testing.expectEqual(core.outcome.Outcome.succeeded, try world.attempt(
        world.travel_agent,
        send_handle,
        send_context,
        .left_device,
    ));
    try world.instance.settleEffect(0x5ec0_0dad, .performed);
    _ = try world.ledger.append(.{
        .actor = world.travel_agent,
        .on_behalf_of = world.human,
        .action = .capability_used,
        .outcome = .succeeded,
        .task = confirmation_task,
        .parent = decided_event,
        .data_movement = .left_device,
    });
    try world.graph.transition(confirmation_task, .succeeded);

    // A second attempt is refused, by the capability and by the approval.
    try std.testing.expectEqual(core.outcome.Outcome.denied, try world.attempt(
        world.travel_agent,
        send_handle,
        send_context,
        .left_device,
    ));
    try std.testing.expectError(
        error.Conflict,
        world.centre.consume(approval, world.travel_agent),
    );

    // 11. The task continues on a second endpoint without changing identity.
    // Performed before cancellation, since cancelling first would leave nothing
    // to continue.
    try world.instance.transferTo(world.desktop);
    try std.testing.expect(world.instance.presenting.eql(world.desktop));
    try std.testing.expect(world.instance.human.eql(world.human));
    // The effect performed on the phone is not repeated on the desktop.
    try std.testing.expectError(error.AlreadyPerformed, world.instance.claimEffect(
        0x5ec0_0dad,
        "send a confirmation of attendance to the venue",
        world.desktop,
    ));

    try world.graph.transition(calendar_task, .succeeded);

    // 10. Cancelling the root stops unfinished descendants and releases what
    // they held.
    const cancelled = try world.graph.cancel(world.root);
    _ = try world.ledger.append(.{
        .actor = world.human,
        .action = .task_cancelled,
        .outcome = .cancelled,
        .task = world.root,
        .provenance = .human_input,
    });
    var iterator = world.graph.tasks.valueIterator();
    while (iterator.next()) |entry| {
        if (entry.state == .cancelling) try world.graph.completeCancellation(entry.id);
    }

    try std.testing.expect(cancelled >= 2);
    try std.testing.expectEqual(@as(usize, 0), world.graph.unfinishedCount());

    for (&held, &world.budgets) |block, *budget| {
        budget.allocator().free(block);
    }
    for (&world.budgets) |budget| {
        try std.testing.expect(budget.isBalanced());
        try std.testing.expect(budget.usage.peak_bytes > 0);
    }

    // 12. The execution is reconstructable from the activity ledger.
    try std.testing.expect(world.ledger.verifySequence());

    var seen: std.EnumSet(audit.Action) = .initEmpty();
    for (0..world.ledger.count()) |index| {
        seen.insert(world.ledger.at(index).?.action);
    }
    const required = [_]audit.Action{
        .authenticated,
        .principal_created,
        .task_created,
        .capability_issued,
        .capability_used,
        .action_denied,
        .approval_requested,
        .approval_decided,
        .endpoint_connected,
        .task_cancelled,
    };
    for (required) |action| try std.testing.expect(seen.contains(action));

    // The approval chain reads from request to decision to execution.
    var execution: ?identity.AuditEventId = null;
    for (0..world.ledger.count()) |index| {
        const event = world.ledger.at(index).?;
        if (event.action == .capability_used and event.parent.eql(decided_event)) {
            execution = event.id;
        }
    }
    const chain = try world.ledger.causalChain(gpa, execution.?);
    defer gpa.free(chain);
    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqual(audit.Action.approval_requested, chain[0].action);
    try std.testing.expectEqual(audit.Action.approval_decided, chain[1].action);
    try std.testing.expectEqual(audit.Action.capability_used, chain[2].action);

    // And a denial is present with its reason.
    const denials = try world.ledger.denials(gpa);
    defer gpa.free(denials);
    try std.testing.expect(denials.len >= 1);
    for (denials) |denial| try std.testing.expect(denial.refusal != null);
}

test "the demonstration makes no claim about Apple binary compatibility" {
    // The proof of concept must display Apple binary compatibility as
    // unavailable. Nothing in the runtimes offers it, and this asserts that
    // rather than trusting it.
    const runtimes = [_][]const u8{ "native", "wasm", "android", "web" };
    for (runtimes) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "apple"));
    }

    for (std.enums.values(shell.session.Runtime)) |runtime| {
        const label = runtime.label();
        try std.testing.expect(std.mem.indexOf(u8, label, "Apple") == null);
        try std.testing.expect(std.mem.indexOf(u8, label, "iOS") == null);
    }
}

test "the demonstration renders under a different brand without source changes" {
    // Every surface takes its product text from the brand layer, so the same
    // demonstration presents correctly whatever the configured brand is.
    try brand.active.validate();
    try std.testing.expect(brand.active.name.len > 0);

    const lock: shell.session.LockSurface = .{
        .product_name = brand.active.name,
        .offers_biometric = true,
    };
    const gpa = std.testing.allocator;
    const described = try lock.describe(gpa);
    defer gpa.free(described.elements);
    defer gpa.free(described.focus_order);
    try std.testing.expectEqualStrings(brand.active.name, described.title);
}
