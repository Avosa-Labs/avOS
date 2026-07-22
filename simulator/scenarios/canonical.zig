//! The canonical scenario.
//!
//! A human asks for help preparing for a scheduled event. The request becomes a
//! visible task graph; three agents work independent branches concurrently with
//! different authority; one branch is refused an operation it was never granted;
//! one consequential action is held for a human decision; the approval yields
//! narrow single-use authority that executes exactly once; and cancelling the
//! root stops what is unfinished and releases what it held.
//!
//! Nothing here is staged. Every step runs through the same checks a real
//! caller faces, and the denial and the approval are produced by the authority
//! model rather than asserted by the scenario.

const std = @import("std");
const core = @import("core");
const host_module = @import("../host/host.zig");
const model = @import("../model/model.zig");

const identity = core.identity;
const time = core.time;
const capability_model = core.capability;
const task_model = core.task;
const audit = core.audit;

const Host = host_module.Host;

/// What the run produced, for a caller to inspect or assert against.
pub const Report = struct {
    root_task: identity.TaskId,
    /// Bytes held across agent budgets before any work began.
    baseline_bytes: usize,
    /// Highest combined agent consumption during the run.
    peak_bytes: usize,
    /// Bytes still held after cancellation completed.
    residual_bytes: usize,
    denials: usize,
    approvals_requested: usize,
    /// Times the approved action actually executed.
    approved_executions: usize,
    /// Times executing it again was refused.
    replay_refusals: usize,
    tasks_cancelled: usize,
    unfinished_tasks: usize,
    ledger_events: usize,
    data_left_device: bool,
};

fn operationSet(operations: []const capability_model.Operation) capability_model.OperationSet {
    var set: capability_model.OperationSet = .initEmpty();
    for (operations) |operation| set.insert(operation);
    return set;
}

/// Runs the scenario against an initialized host.
pub fn run(host: *Host) !Report {
    const human = try host.authenticateHuman("operator");

    // The request becomes a root task before any agent exists, so every branch
    // has an owner and a purpose from the moment it is created.
    const root = try host.graph.create(.{
        .owner = human,
        .requester = human,
        .purpose = "prepare for the scheduled event",
        .deadline = host.now().plus(.fromSeconds(3_600)),
        .budget_bytes = 256 * 1024,
    });
    _ = try host.ledger.append(.{
        .actor = human,
        .action = .task_created,
        .outcome = .succeeded,
        .task = root,
        .provenance = .human_input,
    });

    const calendar = try host.enrollAgent("calendar", .fromSeconds(3_600));
    const documents = try host.enrollAgent("documents", .fromSeconds(3_600));
    const travel = try host.enrollAgent("travel", .fromSeconds(3_600));

    // Authority differs per agent: each holds only what its branch needs.
    const calendar_handle = try host.grant(
        calendar,
        "calendar",
        operationSet(&.{ .read, .list }),
        .{ .local_processing_only = true },
    );
    const documents_handle = try host.grant(
        documents,
        "document",
        operationSet(&.{ .read, .list }),
        .{ .local_processing_only = true },
    );
    const travel_handle = try host.grant(
        travel,
        "route",
        operationSet(&.{.read}),
        .{ .network_destinations = &.{"routing.invalid"} },
    );

    calendar.task = try host.graph.create(.{
        .owner = calendar.id,
        .requester = human,
        .purpose = "inspect the calendar",
        .parent = root,
        .budget_bytes = host.options.agent_budget_bytes,
    });
    documents.task = try host.graph.create(.{
        .owner = documents.id,
        .requester = human,
        .purpose = "retrieve local documents",
        .parent = root,
        .budget_bytes = host.options.agent_budget_bytes,
    });
    travel.task = try host.graph.create(.{
        .owner = travel.id,
        .requester = human,
        .purpose = "plan the route",
        .parent = root,
        .budget_bytes = host.options.agent_budget_bytes,
    });

    const baseline_bytes = host.liveAgentBytes();

    try host.graph.transition(root, .runnable);
    try host.graph.transition(root, .running);

    // Each branch allocates through its own budget, so consumption is
    // attributable and a branch cannot starve the others.
    var branch_state: [3][]u8 = undefined;
    var branch_count: usize = 0;
    errdefer for (branch_state[0..branch_count], 0..) |block, index| {
        host.agents.items[index].budget.allocator().free(block);
    };

    for ([_]*host_module.Agent{ calendar, documents, travel }) |agent| {
        agent.budget.attribution = .{ .principal = agent.id, .task = agent.task };
        try host.graph.transition(agent.task, .runnable);
        try host.graph.transition(agent.task, .running);
        branch_state[branch_count] = try agent.budget.allocator().alloc(u8, 4 * 1024);
        branch_count += 1;
    }

    // The calendar branch reads what it holds and finishes.
    _ = try host.attempt(calendar, calendar_handle, .{
        .holder = calendar.id,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .task = calendar.task,
    }, .stayed_local, .none);
    host.manual.advance(.fromSeconds(1));

    // The documents branch is refused an operation it was never granted. The
    // refusal comes from the capability model, not from the scenario.
    const refused = host.attempt(documents, documents_handle, .{
        .holder = documents.id,
        .operation = .delete,
        .resource = .{ .kind = "document" },
        .task = documents.task,
    }, .not_applicable, .none);
    std.debug.assert(refused == error.Unauthorized);

    // It then does the work it does hold authority for.
    _ = try host.attempt(documents, documents_handle, .{
        .holder = documents.id,
        .operation = .read,
        .resource = .{ .kind = "document" },
        .task = documents.task,
    }, .stayed_local, .none);

    // The travel branch reaches an approved external destination.
    _ = try host.attempt(travel, travel_handle, .{
        .holder = travel.id,
        .operation = .read,
        .resource = .{ .kind = "route" },
        .task = travel.task,
        .network_destination = "routing.invalid",
        .processing_is_local = false,
    }, .left_device, .none);

    // Sending a confirmation is consequential, so it is held for a human.
    const confirmation_task = try host.graph.create(.{
        .owner = travel.id,
        .requester = human,
        .purpose = "confirm attendance with the venue",
        .parent = travel.task,
        .budget_bytes = 4 * 1024,
    });
    try host.graph.transition(confirmation_task, .waiting_for_approval);

    const approval = try host.approvals.request(.{
        .requester = travel.id,
        .approver = human,
        .task = confirmation_task,
        .operation = .send,
        .target_kind = "message",
        .summary = "send a confirmation of attendance to the venue",
    });
    const approval_event = try host.ledger.append(.{
        .actor = travel.id,
        .on_behalf_of = human,
        .action = .approval_requested,
        .outcome = .awaiting_approval,
        .task = confirmation_task,
        .target_kind = "message",
    });

    host.manual.advance(.fromSeconds(5));
    try host.approvals.decide(approval, human, .approved);
    const decision_event = try host.ledger.append(.{
        .actor = human,
        .action = .approval_decided,
        .outcome = .succeeded,
        .task = confirmation_task,
        .parent = approval_event,
        .provenance = .human_input,
    });

    const granted = try host.approvals.consume(approval, travel.id);

    // The decision produces narrow authority: one use, bound to the task that
    // asked, requiring the confirmation that just happened.
    const send_handle = try host.capabilities.issue(.{
        .issuer = human,
        .holder = travel.id,
        .resource = .{ .kind = "message" },
        .operations = operationSet(&.{.send}),
        .constraints = blk: {
            var constraints = core.policy.constraintsForApproval(
                granted,
                host.now().plus(.fromSeconds(300)),
            );
            constraints.recipients = &.{"the venue"};
            break :blk constraints;
        },
    });

    const send_context: capability_model.UseContext = .{
        .holder = travel.id,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .task = confirmation_task,
        .recipient = "the venue",
        .human_confirmed = true,
        .processing_is_local = false,
    };

    try host.graph.transition(confirmation_task, .runnable);
    try host.graph.transition(confirmation_task, .running);

    var approved_executions: usize = 0;
    var replay_refusals: usize = 0;

    _ = try host.attempt(travel, send_handle, send_context, .left_device, decision_event);
    approved_executions += 1;
    try host.graph.transition(confirmation_task, .succeeded);

    // Attempting it again must fail: the grant was spent by the first use.
    if (host.attempt(travel, send_handle, send_context, .left_device, decision_event)) |_| {
        approved_executions += 1;
    } else |_| {
        replay_refusals += 1;
    }

    // Replaying the approval itself must fail for the same reason.
    if (host.approvals.consume(approval, travel.id)) |_| {
        approved_executions += 1;
    } else |_| {
        replay_refusals += 1;
    }

    try host.graph.transition(calendar.task, .succeeded);
    const peak_bytes = host.peakAgentBytes();

    // Cancelling the root stops what remains and releases what it held.
    const cancelled = try host.graph.cancel(root);
    _ = try host.ledger.append(.{
        .actor = human,
        .action = .task_cancelled,
        .outcome = .cancelled,
        .task = root,
        .provenance = .human_input,
    });

    // Winding-down tasks confirm they have stopped before the run concludes.
    var iterator = host.graph.tasks.valueIterator();
    while (iterator.next()) |entry| {
        if (entry.state == .cancelling) try host.graph.completeCancellation(entry.id);
    }

    // Task-owned memory is released as part of stopping, not left to a
    // collector. A branch that finished and a branch that was cancelled both
    // return to baseline.
    for (branch_state[0..branch_count], 0..) |block, index| {
        host.agents.items[index].budget.allocator().free(block);
    }
    branch_count = 0;

    const denials = try host.ledger.denials(host.gpa);
    defer host.gpa.free(denials);

    return .{
        .root_task = root,
        .baseline_bytes = baseline_bytes,
        .peak_bytes = peak_bytes,
        .residual_bytes = host.liveAgentBytes(),
        .denials = denials.len,
        .approvals_requested = 1,
        .approved_executions = approved_executions,
        .replay_refusals = replay_refusals,
        .tasks_cancelled = cancelled,
        .unfinished_tasks = host.graph.unfinishedCount(),
        .ledger_events = host.ledger.count(),
        .data_left_device = host.ledger.anyDataLeftDevice(),
    };
}

test "one human and three agents execute with differing authority" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    _ = try run(&host);

    try std.testing.expectEqual(@as(usize, 3), host.agents.items.len);
    try std.testing.expectEqual(@as(usize, 4), host.registry.count());

    // No two agents hold the same authority.
    const calendar = host.agentNamed("calendar").?;
    const travel = host.agentNamed("travel").?;
    const calendar_grant = host.capabilities.lookup(calendar.handles.items[0].id).?;
    const travel_grant = host.capabilities.lookup(travel.handles.items[0].id).?;

    try std.testing.expect(!std.mem.eql(u8, calendar_grant.resource.kind, travel_grant.resource.kind));
    try std.testing.expect(calendar_grant.constraints.local_processing_only);
    try std.testing.expect(!travel_grant.constraints.local_processing_only);
}

test "an unauthorized operation is denied and recorded" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    const report = try run(&host);

    try std.testing.expect(report.denials >= 1);

    const denials = try host.ledger.denials(gpa);
    defer gpa.free(denials);

    var found_document_denial = false;
    for (denials) |event| {
        if (std.mem.eql(u8, event.target_kind, "document")) {
            try std.testing.expectEqual(core.outcome.DomainError.Unauthorized, event.refusal.?);
            found_document_denial = true;
        }
    }
    try std.testing.expect(found_document_denial);
}

test "an approved action executes exactly once" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    const report = try run(&host);

    try std.testing.expectEqual(@as(usize, 1), report.approvals_requested);
    try std.testing.expectEqual(@as(usize, 1), report.approved_executions);
    // Both the capability replay and the approval replay were refused.
    try std.testing.expectEqual(@as(usize, 2), report.replay_refusals);
}

test "cancelling the root ends every unfinished descendant" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    const report = try run(&host);

    try std.testing.expect(report.tasks_cancelled >= 2);
    try std.testing.expectEqual(@as(usize, 0), report.unfinished_tasks);
    try std.testing.expectEqual(task_model.State.cancelled, host.graph.get(report.root_task).?.state);
}

test "memory returns to baseline after the run" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    const report = try run(&host);

    try std.testing.expect(report.peak_bytes > report.baseline_bytes);
    try std.testing.expectEqual(report.baseline_bytes, report.residual_bytes);
    try std.testing.expect(host.allAgentBudgetsBalanced());
}

test "the execution is reconstructable from the ledger" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    const report = try run(&host);

    try std.testing.expect(host.ledger.verifySequence());
    try std.testing.expect(report.ledger_events > 10);

    // The required events are all present.
    var seen: std.EnumSet(audit.Action) = .initEmpty();
    for (0..host.ledger.count()) |index| {
        seen.insert(host.ledger.at(index).?.action);
    }
    const required = [_]audit.Action{
        .authenticated,
        .principal_created,
        .capability_issued,
        .capability_used,
        .task_created,
        .action_denied,
        .approval_requested,
        .approval_decided,
        .task_cancelled,
    };
    for (required) |action| try std.testing.expect(seen.contains(action));
}

test "the approval chain is traceable from execution back to the request" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    _ = try run(&host);

    // Find the send that followed the decision and walk back to the request.
    var execution: ?identity.AuditEventId = null;
    for (0..host.ledger.count()) |index| {
        const event = host.ledger.at(index).?;
        if (event.action == .capability_used and !event.parent.isNone()) execution = event.id;
    }

    const chain = try host.ledger.causalChain(gpa, execution.?);
    defer gpa.free(chain);

    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqual(audit.Action.approval_requested, chain[0].action);
    try std.testing.expectEqual(audit.Action.approval_decided, chain[1].action);
    try std.testing.expectEqual(audit.Action.capability_used, chain[2].action);
}

test "whether data left the device is answerable from the ledger" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    const report = try run(&host);
    try std.testing.expect(report.data_left_device);
}

test "two runs with the same seed produce the same report" {
    const gpa = std.testing.allocator;

    var first: Host = undefined;
    Host.init(&first, gpa, .{ .seed = 1234 });
    defer first.deinit();
    const first_report = try run(&first);

    var second: Host = undefined;
    Host.init(&second, gpa, .{ .seed = 1234 });
    defer second.deinit();
    const second_report = try run(&second);

    try std.testing.expect(first_report.root_task.eql(second_report.root_task));
    try std.testing.expectEqual(first_report.denials, second_report.denials);
    try std.testing.expectEqual(first_report.ledger_events, second_report.ledger_events);
    try std.testing.expectEqual(first_report.peak_bytes, second_report.peak_bytes);
    try std.testing.expectEqual(first_report.tasks_cancelled, second_report.tasks_cancelled);
}
