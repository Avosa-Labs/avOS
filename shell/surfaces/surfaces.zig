//! Shell surfaces, projected from control-plane state.
//!
//! A surface is a view of what the system actually holds. Nothing here invents
//! a value, caches a stale one, or renders what a model claimed: each surface
//! reads the task graph, the capability store, the approval centre, and the
//! ledger, and shows what is there.
//!
//! That is what makes the interface honest. A surface cannot show an action as
//! complete before it is, because completion is a state it reads rather than a
//! flag it sets, and it cannot hide a principal or a denial, because both come
//! from records it does not own.
//!
//! Every user-facing string that names the product comes from the brand layer.
//! Surfaces hold structure and labels for what things are, never product
//! naming.

const std = @import("std");
const core = @import("core");
const design = @import("design");

const identity = core.identity;
const task_model = core.task;
const audit = core.audit;
const policy_model = core.policy;
const outcome_model = core.outcome;

const accessibility = design.accessibility;
const tokens = design.tokens;

/// The surfaces the shell presents. Exactly these; no more is implied.
pub const Kind = enum {
    lock,
    home,
    command,
    task_graph,
    approvals,
    activity,
    launcher,
    principals,
    capabilities,
    resources,
    endpoints,
    settings,

    /// Whether the surface is reachable before a human has authenticated.
    pub fn availableWhenLocked(kind: Kind) bool {
        return kind == .lock;
    }

    /// Whether the command surface may be opened from here.
    ///
    /// It may be opened from everywhere except the lock screen, because a
    /// command surface reachable before authentication would accept intent from
    /// whoever is holding the device.
    pub fn allowsCommandEntry(kind: Kind) bool {
        return kind != .lock;
    }
};

/// How a task's state is presented, including the words that carry the meaning
/// when colour cannot.
pub const StateLabel = struct {
    text: []const u8,
    colour_role: tokens.ColourRole,
};

/// The label for a task state.
///
/// Every state has one. A state that fell through to a default would appear on
/// screen as whatever the default said, which is how a cancelled task comes to
/// look like a running one.
pub fn labelForTaskState(state: task_model.State) StateLabel {
    return switch (state) {
        .planned => .{ .text = "Planned", .colour_role = .text_secondary },
        .waiting_for_dependency => .{ .text = "Waiting on another step", .colour_role = .text_secondary },
        .waiting_for_capability => .{ .text = "Waiting for authority", .colour_role = .status_awaiting_approval },
        .waiting_for_approval => .{ .text = "Waiting for your approval", .colour_role = .status_awaiting_approval },
        .runnable => .{ .text = "Ready", .colour_role = .text_secondary },
        .running => .{ .text = "Running", .colour_role = .status_running },
        .cancelling => .{ .text = "Stopping", .colour_role = .status_cancelled },
        .cancelled => .{ .text = "Cancelled", .colour_role = .status_cancelled },
        .succeeded => .{ .text = "Done", .colour_role = .status_succeeded },
        .failed => .{ .text = "Failed", .colour_role = .status_failed },
    };
}

/// The label for a recorded outcome.
pub fn labelForOutcome(value: outcome_model.Outcome) StateLabel {
    return switch (value) {
        .succeeded => .{ .text = "Done", .colour_role = .status_succeeded },
        .denied => .{ .text = "Denied", .colour_role = .status_denied },
        .failed => .{ .text = "Failed", .colour_role = .status_failed },
        .cancelled => .{ .text = "Cancelled", .colour_role = .status_cancelled },
        .awaiting_approval => .{ .text = "Waiting for your approval", .colour_role = .status_awaiting_approval },
        // Deliberately not presented as a failure: the action may have taken
        // effect, and telling the user it did not would be a false statement
        // about the outside world.
        .outcome_unknown => .{ .text = "Result unknown", .colour_role = .status_awaiting_approval },
    };
}

/// One row of the task graph.
pub const TaskRow = struct {
    id: identity.TaskId,
    depth: u8,
    purpose: []const u8,
    state: task_model.State,
    label: StateLabel,
    /// Whether the user may cancel this task from here.
    cancellable: bool,
};

/// One row of the activity ledger.
pub const ActivityRow = struct {
    sequence: u64,
    actor: identity.PrincipalId,
    action: audit.Action,
    outcome: outcome_model.Outcome,
    label: StateLabel,
    /// Shown so a user can see what left the device without opening anything.
    left_device: bool,
    /// The reason, when the action was refused.
    refusal_text: []const u8,
};

/// One pending approval.
pub const ApprovalRow = struct {
    id: identity.ApprovalId,
    summary: []const u8,
    consequence: policy_model.Consequence,
    /// Whether the decision expires, and the user should be told it will.
    expires: bool,
};

pub const Error = error{
    /// The surface was requested before a human authenticated.
    NotAuthenticated,
    /// The surface would present more rows than it can bound.
    TooManyRows,
};

/// Largest number of rows a surface materializes at once.
///
/// Surfaces page rather than loading everything: a ledger or a task graph grows
/// without limit, and a surface that rendered all of it would stall exactly
/// when the system is busiest.
pub const max_rows: usize = 256;

/// What the shell knows about the session presenting these surfaces.
pub const Session = struct {
    authenticated: bool,
    human: identity.PrincipalId,
    preferences: accessibility.Preferences = .standard,
};

/// Projects the task graph into rows, depth-first from each root.
///
/// Caller owns the returned slice. Rows are produced in the order a reader
/// follows them, so the same order serves the visual layout and the
/// accessibility traversal rather than the two being maintained separately.
pub fn projectTaskGraph(
    gpa: std.mem.Allocator,
    graph: *const task_model.Graph,
    session: Session,
) ![]TaskRow {
    if (!session.authenticated) return error.NotAuthenticated;

    var rows: std.ArrayList(TaskRow) = .empty;
    errdefer rows.deinit(gpa);

    for (graph.roots.items) |root| {
        try appendTaskRow(gpa, graph, root, 0, &rows);
    }
    return rows.toOwnedSlice(gpa);
}

fn appendTaskRow(
    gpa: std.mem.Allocator,
    graph: *const task_model.Graph,
    id: identity.TaskId,
    depth: u8,
    rows: *std.ArrayList(TaskRow),
) !void {
    if (rows.items.len >= max_rows) return error.TooManyRows;
    const task = graph.get(id) orelse return;

    try rows.append(gpa, .{
        .id = id,
        .depth = depth,
        .purpose = task.purpose,
        .state = task.state,
        .label = labelForTaskState(task.state),
        // Finished work cannot be cancelled, and offering the control would
        // imply the system might still stop something that already happened.
        .cancellable = !task.state.isTerminal(),
    });

    for (task.children.items) |child| {
        try appendTaskRow(gpa, graph, child, depth +| 1, rows);
    }
}

/// Projects the ledger into rows, most recent last.
///
/// Caller owns the returned slice.
pub fn projectActivity(
    gpa: std.mem.Allocator,
    ledger: *const audit.Ledger,
    session: Session,
    limit: usize,
) ![]ActivityRow {
    if (!session.authenticated) return error.NotAuthenticated;

    const bounded = @min(limit, max_rows);
    const total = ledger.count();
    const start = if (total > bounded) total - bounded else 0;

    var rows: std.ArrayList(ActivityRow) = .empty;
    errdefer rows.deinit(gpa);

    var index = start;
    while (index < total) : (index += 1) {
        const event = ledger.at(index) orelse continue;
        try rows.append(gpa, .{
            .sequence = event.sequence,
            .actor = event.actor,
            .action = event.action,
            .outcome = event.outcome,
            .label = labelForOutcome(event.outcome),
            .left_device = event.data_movement == .left_device,
            .refusal_text = if (event.refusal) |refusal|
                outcome_model.describe(refusal)
            else
                "",
        });
    }
    return rows.toOwnedSlice(gpa);
}

/// Projects pending approvals.
///
/// Caller owns the returned slice.
pub fn projectApprovals(
    gpa: std.mem.Allocator,
    centre: *const policy_model.Centre,
    session: Session,
) ![]ApprovalRow {
    if (!session.authenticated) return error.NotAuthenticated;

    var rows: std.ArrayList(ApprovalRow) = .empty;
    errdefer rows.deinit(gpa);

    var iterator = centre.requests.valueIterator();
    while (iterator.next()) |request| {
        if (request.state != .pending) continue;
        if (!request.approver.eql(session.human)) continue;
        if (rows.items.len >= max_rows) return error.TooManyRows;
        try rows.append(gpa, .{
            .id = request.id,
            .summary = request.summary,
            .consequence = request.consequence,
            .expires = request.expires_at != null,
        });
    }
    return rows.toOwnedSlice(gpa);
}

/// Builds the accessibility view of the approvals surface.
///
/// The structure is derived from the same rows the visual layout uses, so the
/// two cannot drift: an approval the eye can see is one assistive technology
/// can reach, because both come from this projection.
pub fn describeApprovals(
    gpa: std.mem.Allocator,
    rows: []const ApprovalRow,
) !accessibility.Surface {
    var elements: std.ArrayList(accessibility.Element) = .empty;
    errdefer elements.deinit(gpa);
    var order: std.ArrayList(usize) = .empty;
    errdefer order.deinit(gpa);

    try elements.append(gpa, .{ .role = .heading, .accessible_name = "Waiting for approval" });

    for (rows) |row| {
        try order.append(gpa, elements.items.len);
        try elements.append(gpa, .{
            .role = .list_item,
            .accessible_name = row.summary,
            .status = .status_awaiting_approval,
            .status_text = "Waiting for your approval",
        });
    }

    return .{
        .title = "Approvals",
        .elements = try elements.toOwnedSlice(gpa),
        .focus_order = try order.toOwnedSlice(gpa),
    };
}

/// Whether an action may proceed without a further human decision.
///
/// The surface never decides this. It asks, and reflects the answer, so an
/// interface change can never widen what runs without approval.
pub fn requiresApproval(
    policy: policy_model.Policy,
    operation: core.capability.Operation,
) bool {
    return policy.evaluate(.ofOperation(operation)).requiresHuman();
}

test "every task state has a distinct label and a status colour" {
    const gpa = std.testing.allocator;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    for (std.enums.values(task_model.State)) |state| {
        const label = labelForTaskState(state);
        try std.testing.expect(label.text.len > 0);
        const entry = try seen.getOrPut(gpa, label.text);
        // Two states sharing a label would make them indistinguishable on
        // screen, which is how a cancelled task comes to look like a done one.
        try std.testing.expect(!entry.found_existing);
    }
}

test "every outcome has a label and none is presented as success wrongly" {
    for (std.enums.values(outcome_model.Outcome)) |value| {
        const label = labelForOutcome(value);
        try std.testing.expect(label.text.len > 0);
        if (value != .succeeded) {
            try std.testing.expect(label.colour_role != .status_succeeded);
        }
    }
}

test "an unknown external result is not presented as a failure" {
    // It may have taken effect. Telling the user it did not would be a false
    // statement about the outside world.
    const label = labelForOutcome(.outcome_unknown);
    try std.testing.expect(label.colour_role != .status_failed);
    try std.testing.expect(label.colour_role != .status_succeeded);
}

test "only the lock surface is reachable before authentication" {
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expectEqual(kind == .lock, kind.availableWhenLocked());
        try std.testing.expectEqual(kind != .lock, kind.allowsCommandEntry());
    }
}

const Fixture = struct {
    ids: identity.Source,
    manual: core.time.ManualClock,
    graph: task_model.Graph,
    ledger: audit.Ledger,
    centre: policy_model.Centre,
    human: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) void {
        fixture.* = .{
            .ids = .initDeterministic(9090),
            .manual = .init(.fromSeconds(1_000)),
            .graph = undefined,
            .ledger = undefined,
            .centre = undefined,
            .human = .{ .value = 1 },
        };
        const clock = fixture.manual.clock();
        fixture.graph = .init(gpa, &fixture.ids, clock);
        fixture.ledger = .init(gpa, &fixture.ids, clock);
        fixture.centre = .init(gpa, &fixture.ids, clock, .strict);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.centre.deinit();
        fixture.ledger.deinit();
        fixture.graph.deinit();
    }

    fn session(fixture: *Fixture) Session {
        return .{ .authenticated = true, .human = fixture.human };
    }
};

test "the task graph is projected depth-first with its structure intact" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.graph.create(.{
        .owner = fixture.human,
        .requester = fixture.human,
        .purpose = "prepare for the event",
        .budget_bytes = 4096,
    });
    const branch = try fixture.graph.create(.{
        .owner = fixture.human,
        .requester = fixture.human,
        .purpose = "plan the route",
        .parent = root,
        .budget_bytes = 4096,
    });
    _ = try fixture.graph.create(.{
        .owner = fixture.human,
        .requester = fixture.human,
        .purpose = "query the routing service",
        .parent = branch,
        .budget_bytes = 4096,
    });

    const rows = try projectTaskGraph(gpa, &fixture.graph, fixture.session());
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(u8, 0), rows[0].depth);
    try std.testing.expectEqual(@as(u8, 1), rows[1].depth);
    try std.testing.expectEqual(@as(u8, 2), rows[2].depth);
    try std.testing.expectEqualStrings("prepare for the event", rows[0].purpose);
}

test "a finished task offers no cancellation control" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.graph.create(.{
        .owner = fixture.human,
        .requester = fixture.human,
        .purpose = "prepare for the event",
        .budget_bytes = 4096,
    });
    try fixture.graph.transition(root, .runnable);
    try fixture.graph.transition(root, .running);

    const running = try projectTaskGraph(gpa, &fixture.graph, fixture.session());
    try std.testing.expect(running[0].cancellable);
    gpa.free(running);

    try fixture.graph.transition(root, .succeeded);
    const finished = try projectTaskGraph(gpa, &fixture.graph, fixture.session());
    defer gpa.free(finished);
    try std.testing.expect(!finished[0].cancellable);
}

test "no surface is projected before a human authenticates" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const locked: Session = .{ .authenticated = false, .human = .none };

    try std.testing.expectError(
        error.NotAuthenticated,
        projectTaskGraph(gpa, &fixture.graph, locked),
    );
    try std.testing.expectError(
        error.NotAuthenticated,
        projectActivity(gpa, &fixture.ledger, locked, 10),
    );
    try std.testing.expectError(
        error.NotAuthenticated,
        projectApprovals(gpa, &fixture.centre, locked),
    );
}

test "a denial appears in the activity surface with its reason" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    _ = try fixture.ledger.append(.{
        .actor = .{ .value = 2 },
        .action = .action_denied,
        .outcome = .denied,
        .refusal = error.Unauthorized,
    });

    const rows = try projectActivity(gpa, &fixture.ledger, fixture.session(), 10);
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(outcome_model.Outcome.denied, rows[0].outcome);
    try std.testing.expectEqualStrings("Denied", rows[0].label.text);
    try std.testing.expectEqualStrings("not authorized", rows[0].refusal_text);
}

test "data leaving the device is visible without opening anything" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    _ = try fixture.ledger.append(.{
        .actor = .{ .value = 2 },
        .action = .tool_invoked,
        .outcome = .succeeded,
        .data_movement = .left_device,
    });
    _ = try fixture.ledger.append(.{
        .actor = .{ .value = 2 },
        .action = .tool_invoked,
        .outcome = .succeeded,
        .data_movement = .stayed_local,
    });

    const rows = try projectActivity(gpa, &fixture.ledger, fixture.session(), 10);
    defer gpa.free(rows);

    try std.testing.expect(rows[0].left_device);
    try std.testing.expect(!rows[1].left_device);
}

test "the activity surface pages rather than loading the whole ledger" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    for (0..600) |_| {
        _ = try fixture.ledger.append(.{
            .actor = .{ .value = 2 },
            .action = .capability_used,
            .outcome = .succeeded,
        });
    }

    const rows = try projectActivity(gpa, &fixture.ledger, fixture.session(), 1_000);
    defer gpa.free(rows);

    try std.testing.expectEqual(max_rows, rows.len);
    // The most recent events are the ones shown.
    try std.testing.expectEqual(@as(u64, 600), rows[rows.len - 1].sequence);
}

test "only the deciding human sees a pending approval" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const other_human: identity.PrincipalId = .{ .value = 77 };
    _ = try fixture.centre.request(.{
        .requester = .{ .value = 2 },
        .approver = fixture.human,
        .task = .{ .value = 3 },
        .operation = .send,
        .target_kind = "message",
        .summary = "send a confirmation to the venue",
    });

    const mine = try projectApprovals(gpa, &fixture.centre, fixture.session());
    defer gpa.free(mine);
    try std.testing.expectEqual(@as(usize, 1), mine.len);

    const theirs = try projectApprovals(gpa, &fixture.centre, .{
        .authenticated = true,
        .human = other_human,
    });
    defer gpa.free(theirs);
    try std.testing.expectEqual(@as(usize, 0), theirs.len);
}

test "a decided approval leaves the pending surface" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const id = try fixture.centre.request(.{
        .requester = .{ .value = 2 },
        .approver = fixture.human,
        .task = .{ .value = 3 },
        .operation = .send,
        .target_kind = "message",
        .summary = "send a confirmation to the venue",
    });

    try fixture.centre.decide(id, fixture.human, .approved);

    const rows = try projectApprovals(gpa, &fixture.centre, fixture.session());
    defer gpa.free(rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

test "the approvals surface satisfies the accessibility contract" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    _ = try fixture.centre.request(.{
        .requester = .{ .value = 2 },
        .approver = fixture.human,
        .task = .{ .value = 3 },
        .operation = .send,
        .target_kind = "message",
        .summary = "send a confirmation to the venue",
    });

    const rows = try projectApprovals(gpa, &fixture.centre, fixture.session());
    defer gpa.free(rows);

    var surface = try describeApprovals(gpa, rows);
    defer gpa.free(surface.elements);
    defer gpa.free(surface.focus_order);

    try surface.validate(gpa);
    // Every approval the eye can see is one assistive technology can reach.
    try std.testing.expectEqual(rows.len, surface.focus_order.len);
}

test "the surface never decides whether an action needs approval" {
    const strict: policy_model.Policy = .strict;
    for (std.enums.values(core.capability.Operation)) |operation| {
        try std.testing.expectEqual(
            operation.isConsequential(),
            requiresApproval(strict, operation),
        );
    }
}

test "surfaces hold no product naming" {
    // Product naming belongs to the brand layer. A label defined here would
    // survive a rebrand and contradict every other surface.
    const labels = blk: {
        var collected: [32][]const u8 = undefined;
        var count: usize = 0;
        for (std.enums.values(task_model.State)) |state| {
            collected[count] = labelForTaskState(state).text;
            count += 1;
        }
        for (std.enums.values(outcome_model.Outcome)) |value| {
            collected[count] = labelForOutcome(value).text;
            count += 1;
        }
        break :blk collected[0..count];
    };

    for (labels) |label| {
        try std.testing.expect(label.len > 0);
        // A label is a description of state, not a name for anything.
        try std.testing.expect(std.mem.indexOfScalar(u8, label, '@') == null);
    }
}
