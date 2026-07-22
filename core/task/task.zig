//! The structured task graph.
//!
//! Every agent operation belongs to a task, and every task belongs to a graph
//! with an owner, a purpose, a budget, and a cancellation path. Work that does
//! not appear here does not exist: an agent cannot hide activity by spawning
//! something the graph does not know about.
//!
//! Cancellation is transitive. Cancelling a parent cancels its unfinished
//! descendants, because a subtree exists to serve its parent's purpose and
//! outliving that purpose is exactly how orphaned background work appears. A
//! descendant may only survive by being detached, which requires a fresh owner,
//! purpose, budget, expiration, and capability set — a new grant of authority,
//! not an inherited one.
//!
//! The state machine is total. Every transition is either explicitly allowed or
//! explicitly refused; terminal states stay terminal; and repeating a
//! transition that already happened succeeds without changing anything, so a
//! retried message after a restart cannot corrupt the graph.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const outcome = @import("../base/outcome.zig");
const capability_model = @import("../capability/capability.zig");

const DomainError = outcome.DomainError;

/// Cancellation copies each child list before recursing, so it can fail the way
/// any allocation can. The error set says so rather than hiding it behind a
/// panic on a path that must stay available under memory pressure.
pub const CancelError = DomainError || std.mem.Allocator.Error;

pub const State = enum {
    planned,
    waiting_for_dependency,
    waiting_for_capability,
    waiting_for_approval,
    runnable,
    running,
    cancelling,
    cancelled,
    succeeded,
    failed,

    /// A terminal state is never left. Work that reached one is finished, and
    /// its resources have been released.
    pub fn isTerminal(state: State) bool {
        return switch (state) {
            .cancelled, .succeeded, .failed => true,
            .planned,
            .waiting_for_dependency,
            .waiting_for_capability,
            .waiting_for_approval,
            .runnable,
            .running,
            .cancelling,
            => false,
        };
    }

    /// Whether the task is blocked awaiting something external to it.
    pub fn isBlocked(state: State) bool {
        return switch (state) {
            .waiting_for_dependency, .waiting_for_capability, .waiting_for_approval => true,
            else => false,
        };
    }

    /// Whether cancelling this task requires passing through `cancelling`.
    ///
    /// Work that has begun must be given the chance to stop at a cancellation
    /// point and release what it holds. Work that never started can be
    /// abandoned directly.
    pub fn requiresWindDown(state: State) bool {
        return state == .running;
    }
};

/// Whether a transition is permitted, and why not when it is refused.
pub const Transition = enum {
    allowed,
    /// The task is already in the requested state.
    redundant,
    /// The task has finished; nothing may move it.
    terminal,
    /// The transition is not part of the machine.
    forbidden,
};

/// The complete transition table.
///
/// Written as one function rather than scattered checks so that the machine can
/// be read, and tested, in a single place. Anything not named here is refused.
pub fn classify(from: State, to: State) Transition {
    if (from == to) return .redundant;
    if (from.isTerminal()) return .terminal;

    const allowed = switch (from) {
        .planned => switch (to) {
            .waiting_for_dependency,
            .waiting_for_capability,
            .waiting_for_approval,
            .runnable,
            .cancelled,
            .failed,
            => true,
            else => false,
        },
        .waiting_for_dependency => switch (to) {
            .waiting_for_capability,
            .waiting_for_approval,
            .runnable,
            .cancelled,
            .failed,
            => true,
            else => false,
        },
        .waiting_for_capability => switch (to) {
            .waiting_for_approval, .runnable, .cancelled, .failed => true,
            else => false,
        },
        // A denied approval fails the task; it does not silently proceed.
        .waiting_for_approval => switch (to) {
            .runnable, .cancelled, .failed => true,
            else => false,
        },
        .runnable => switch (to) {
            .running, .waiting_for_dependency, .waiting_for_capability, .cancelled, .failed => true,
            else => false,
        },
        // Running work may block again, wind down, or finish.
        .running => switch (to) {
            .waiting_for_dependency,
            .waiting_for_capability,
            .waiting_for_approval,
            .cancelling,
            .succeeded,
            .failed,
            => true,
            else => false,
        },
        // Winding down may complete an operation that had already committed,
        // which is why `succeeded` is reachable from here.
        .cancelling => switch (to) {
            .cancelled, .succeeded, .failed => true,
            else => false,
        },
        .cancelled, .succeeded, .failed => false,
    };

    return if (allowed) .allowed else .forbidden;
}

/// Why a task stopped, recorded when it reaches a terminal state.
pub const Conclusion = union(enum) {
    completed,
    /// Cancelled directly, or because an ancestor was.
    cancelled_by: identity.TaskId,
    failed_with: DomainError,
};

pub const RetryPolicy = struct {
    /// Attempts permitted in total, including the first. One means no retry.
    max_attempts: u8 = 1,
    /// Whether the work is safe to repeat. Work that is not idempotent is
    /// never retried automatically, because a repeat could duplicate an
    /// external effect.
    idempotent: bool = false,

    pub const none: RetryPolicy = .{};

    pub fn permitsRetry(policy: RetryPolicy, attempts_made: u8) bool {
        if (!policy.idempotent) return false;
        return attempts_made < policy.max_attempts;
    }
};

/// What a task needs before it may be created.
pub const Declaration = struct {
    /// The principal whose authority the work runs under.
    owner: identity.PrincipalId,
    /// The principal that asked for the work. Distinct from the owner when an
    /// agent acts for a human.
    requester: identity.PrincipalId,
    /// Why this task exists, in the domain's own terms.
    purpose: []const u8,
    parent: identity.TaskId = .none,
    deadline: ?time.Timestamp = null,
    budget_bytes: usize = 0,
    retry_policy: RetryPolicy = .none,
};

pub const Task = struct {
    id: identity.TaskId,
    owner: identity.PrincipalId,
    requester: identity.PrincipalId,
    purpose: []const u8,
    parent: identity.TaskId,
    children: std.ArrayList(identity.TaskId),
    dependencies: std.ArrayList(identity.TaskId),
    capabilities: std.ArrayList(capability_model.Handle),
    state: State,
    created_at: time.Timestamp,
    deadline: ?time.Timestamp,
    budget_bytes: usize,
    retry_policy: RetryPolicy,
    attempts_made: u8,
    conclusion: ?Conclusion,
    /// Set when cancellation has been requested, whether or not the task has
    /// reached a cancellation point yet.
    cancellation_requested: bool,
    /// True once the task no longer belongs to its parent's cancellation scope.
    detached: bool,

    /// Whether work should stop at its next cancellation point.
    pub fn isCancellationRequested(task: Task) bool {
        return task.cancellation_requested;
    }

    pub fn hasDeadlinePassed(task: Task, now: time.Timestamp) bool {
        const deadline = task.deadline orelse return false;
        return !deadline.isAfter(now);
    }
};

/// A task graph rooted in one or more root tasks.
///
/// Ownership: the graph owns every task record, the purpose strings it copies,
/// and the child, dependency, and capability lists. `deinit` releases all of
/// them. Callers refer to tasks by identifier, never by pointer, so a structural
/// change cannot invalidate a reference a caller is holding.
///
/// Lookup is expected O(1). Cancellation walks only the subtree below the
/// cancelled task, so its cost is proportional to that subtree and never to the
/// number of unrelated tasks on the host.
pub const Graph = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    clock: time.Clock,
    tasks: std.AutoHashMapUnmanaged(u128, Task) = .empty,
    roots: std.ArrayList(identity.TaskId) = .empty,

    pub fn init(gpa: std.mem.Allocator, ids: *identity.Source, clock: time.Clock) Graph {
        return .{ .gpa = gpa, .ids = ids, .clock = clock };
    }

    pub fn deinit(graph: *Graph) void {
        var iterator = graph.tasks.valueIterator();
        while (iterator.next()) |task| {
            graph.gpa.free(task.purpose);
            task.children.deinit(graph.gpa);
            task.dependencies.deinit(graph.gpa);
            task.capabilities.deinit(graph.gpa);
        }
        graph.tasks.deinit(graph.gpa);
        graph.roots.deinit(graph.gpa);
        graph.* = undefined;
    }

    /// Creates a task and links it to its parent.
    ///
    /// A child of a finished parent is refused: attaching work to a completed
    /// scope would create exactly the orphan the cancellation rules exist to
    /// prevent.
    pub fn create(graph: *Graph, declaration: Declaration) !identity.TaskId {
        if (!declaration.parent.isNone()) {
            const parent = graph.tasks.get(declaration.parent.value) orelse
                return error.InvalidInput;
            if (parent.state.isTerminal()) return error.Conflict;
        }

        const id = graph.ids.next(identity.TaskId);
        const purpose = try graph.gpa.dupe(u8, declaration.purpose);
        errdefer graph.gpa.free(purpose);

        try graph.tasks.put(graph.gpa, id.value, .{
            .id = id,
            .owner = declaration.owner,
            .requester = declaration.requester,
            .purpose = purpose,
            .parent = declaration.parent,
            .children = .empty,
            .dependencies = .empty,
            .capabilities = .empty,
            .state = .planned,
            .created_at = graph.clock.wall(),
            .deadline = declaration.deadline,
            .budget_bytes = declaration.budget_bytes,
            .retry_policy = declaration.retry_policy,
            .attempts_made = 0,
            .conclusion = null,
            .cancellation_requested = false,
            .detached = false,
        });
        errdefer _ = graph.tasks.remove(id.value);

        if (declaration.parent.isNone()) {
            try graph.roots.append(graph.gpa, id);
        } else {
            const parent = graph.tasks.getPtr(declaration.parent.value).?;
            try parent.children.append(graph.gpa, id);
            // A child inherits a cancellation already in flight, so work
            // spawned during wind-down does not escape it.
            if (parent.cancellation_requested) {
                graph.tasks.getPtr(id.value).?.cancellation_requested = true;
            }
        }

        return id;
    }

    pub fn get(graph: Graph, id: identity.TaskId) ?Task {
        return graph.tasks.get(id.value);
    }

    pub fn mustGet(graph: Graph, id: identity.TaskId) DomainError!Task {
        return graph.tasks.get(id.value) orelse error.InvalidInput;
    }

    /// Records that `id` cannot start until `dependency` finishes.
    pub fn addDependency(
        graph: *Graph,
        id: identity.TaskId,
        dependency: identity.TaskId,
    ) !void {
        if (id.eql(dependency)) return error.InvalidInput;
        _ = graph.tasks.get(dependency.value) orelse return error.InvalidInput;
        const task = graph.tasks.getPtr(id.value) orelse return error.InvalidInput;
        // A cycle would make both tasks permanently unrunnable.
        if (try graph.dependsOn(dependency, id)) return error.Conflict;
        try task.dependencies.append(graph.gpa, dependency);
    }

    /// Whether `id` transitively depends on `candidate`.
    fn dependsOn(graph: Graph, id: identity.TaskId, candidate: identity.TaskId) !bool {
        const task = graph.tasks.get(id.value) orelse return false;
        for (task.dependencies.items) |dependency| {
            if (dependency.eql(candidate)) return true;
            if (try graph.dependsOn(dependency, candidate)) return true;
        }
        return false;
    }

    /// Whether every dependency has succeeded.
    pub fn dependenciesSatisfied(graph: Graph, id: identity.TaskId) bool {
        const task = graph.tasks.get(id.value) orelse return false;
        for (task.dependencies.items) |dependency| {
            const record = graph.tasks.get(dependency.value) orelse return false;
            if (record.state != .succeeded) return false;
        }
        return true;
    }

    /// Attaches a capability to the task that will exercise it.
    pub fn grantCapability(
        graph: *Graph,
        id: identity.TaskId,
        handle: capability_model.Handle,
    ) !void {
        const task = graph.tasks.getPtr(id.value) orelse return error.InvalidInput;
        if (task.state.isTerminal()) return error.Conflict;
        try task.capabilities.append(graph.gpa, handle);
    }

    /// Moves a task to a new state.
    ///
    /// Repeating a transition already made succeeds without effect, so a
    /// duplicated message is harmless. A transition out of a terminal state, or
    /// one the machine does not define, is refused.
    pub fn transition(graph: *Graph, id: identity.TaskId, to: State) DomainError!void {
        const task = graph.tasks.getPtr(id.value) orelse return error.InvalidInput;

        switch (classify(task.state, to)) {
            .redundant => return,
            .terminal => return error.Conflict,
            .forbidden => return error.Conflict,
            .allowed => {},
        }

        if (to == .running) task.attempts_made += 1;
        task.state = to;

        if (to.isTerminal() and task.conclusion == null) {
            task.conclusion = switch (to) {
                .succeeded => .completed,
                .cancelled => .{ .cancelled_by = id },
                .failed => .{ .failed_with = error.InternalFault },
                else => unreachable,
            };
        }
    }

    /// Fails a task with a specific reason.
    pub fn fail(graph: *Graph, id: identity.TaskId, reason: DomainError) DomainError!void {
        try graph.transition(id, .failed);
        const task = graph.tasks.getPtr(id.value) orelse return error.InvalidInput;
        task.conclusion = .{ .failed_with = reason };
    }

    /// Cancels a task and every unfinished descendant that has not been
    /// detached.
    ///
    /// Returns how many tasks were affected. The walk covers only the subtree
    /// below `id`; unrelated tasks are never visited, so cancelling a small
    /// branch stays cheap on a host running many graphs.
    pub fn cancel(graph: *Graph, id: identity.TaskId) CancelError!usize {
        const root = graph.tasks.getPtr(id.value) orelse return error.InvalidInput;
        if (root.state.isTerminal()) return 0;
        return graph.cancelSubtree(id, id);
    }

    fn cancelSubtree(
        graph: *Graph,
        id: identity.TaskId,
        cancelled_by: identity.TaskId,
    ) CancelError!usize {
        const task = graph.tasks.getPtr(id.value) orelse return 0;
        if (task.state.isTerminal()) return 0;

        // A detached descendant runs under its own authority and is not part of
        // this cancellation scope. Its own root may still be cancelled.
        if (task.detached and !id.eql(cancelled_by)) return 0;

        task.cancellation_requested = true;

        var affected: usize = 1;
        if (task.state.requiresWindDown()) {
            try graph.transition(id, .cancelling);
        } else {
            try graph.transition(id, .cancelled);
            graph.tasks.getPtr(id.value).?.conclusion = .{ .cancelled_by = cancelled_by };
        }

        // Copy the child list before recursing: the recursion mutates the map,
        // which may move the parent's record.
        const children = try graph.gpa.dupe(
            identity.TaskId,
            graph.tasks.getPtr(id.value).?.children.items,
        );
        defer graph.gpa.free(children);

        for (children) |child| {
            affected += try graph.cancelSubtree(child, cancelled_by);
        }
        return affected;
    }

    /// Confirms a winding-down task has stopped.
    pub fn completeCancellation(graph: *Graph, id: identity.TaskId) DomainError!void {
        const task = graph.tasks.getPtr(id.value) orelse return error.InvalidInput;
        if (task.state != .cancelling) return error.Conflict;
        try graph.transition(id, .cancelled);
        graph.tasks.getPtr(id.value).?.conclusion = .{ .cancelled_by = id };
    }

    /// Removes a task from its parent's cancellation scope.
    ///
    /// Detachment is a new grant of authority, not an inherited one: the work
    /// gets a fresh owner, purpose, budget, and expiration, and from then on it
    /// survives its former parent's cancellation. Without all of them the task
    /// would become exactly the unowned background work the graph exists to
    /// prevent, so an incomplete detachment is refused.
    pub fn detach(
        graph: *Graph,
        id: identity.TaskId,
        new_owner: identity.PrincipalId,
        purpose: []const u8,
        budget_bytes: usize,
        expires_at: time.Timestamp,
    ) !void {
        const task = graph.tasks.getPtr(id.value) orelse return error.InvalidInput;
        if (task.state.isTerminal()) return error.Conflict;
        if (task.cancellation_requested) return error.Cancelled;
        if (new_owner.isNone()) return error.InvalidInput;
        if (purpose.len == 0) return error.InvalidInput;
        if (budget_bytes == 0) return error.InvalidInput;
        if (!expires_at.isAfter(graph.clock.wall())) return error.InvalidInput;

        const owned_purpose = try graph.gpa.dupe(u8, purpose);
        graph.gpa.free(task.purpose);
        task.purpose = owned_purpose;
        task.owner = new_owner;
        task.budget_bytes = budget_bytes;
        task.deadline = expires_at;
        task.detached = true;

        try graph.roots.append(graph.gpa, id);
    }

    /// Number of tasks in the graph, including finished ones.
    pub fn count(graph: Graph) usize {
        return graph.tasks.count();
    }

    /// Number of tasks that have not reached a terminal state.
    pub fn unfinishedCount(graph: Graph) usize {
        var unfinished: usize = 0;
        var iterator = graph.tasks.valueIterator();
        while (iterator.next()) |task| {
            if (!task.state.isTerminal()) unfinished += 1;
        }
        return unfinished;
    }
};

test "the transition table is total" {
    // Every ordered pair of states must be classified. An unclassified pair
    // would be a hole in the machine.
    for (std.enums.values(State)) |from| {
        for (std.enums.values(State)) |to| {
            const classification = classify(from, to);
            if (from == to) {
                try std.testing.expectEqual(Transition.redundant, classification);
            } else if (from.isTerminal()) {
                try std.testing.expectEqual(Transition.terminal, classification);
            }
        }
    }
}

test "terminal states are never left" {
    const terminals = [_]State{ .cancelled, .succeeded, .failed };
    for (terminals) |from| {
        try std.testing.expect(from.isTerminal());
        for (std.enums.values(State)) |to| {
            if (from == to) continue;
            try std.testing.expectEqual(Transition.terminal, classify(from, to));
        }
    }
}

test "a repeated transition is redundant rather than an error" {
    for (std.enums.values(State)) |state| {
        try std.testing.expectEqual(Transition.redundant, classify(state, state));
    }
}

test "planned work cannot jump straight to running or succeeded" {
    try std.testing.expectEqual(Transition.forbidden, classify(.planned, .running));
    try std.testing.expectEqual(Transition.forbidden, classify(.planned, .succeeded));
    try std.testing.expectEqual(Transition.forbidden, classify(.planned, .cancelling));
    try std.testing.expectEqual(Transition.allowed, classify(.planned, .runnable));
}

test "a denied approval fails the task instead of proceeding" {
    try std.testing.expectEqual(Transition.allowed, classify(.waiting_for_approval, .failed));
    try std.testing.expectEqual(Transition.allowed, classify(.waiting_for_approval, .runnable));
    try std.testing.expectEqual(Transition.forbidden, classify(.waiting_for_approval, .running));
    try std.testing.expectEqual(Transition.forbidden, classify(.waiting_for_approval, .succeeded));
}

test "winding down may finish an operation that had already committed" {
    try std.testing.expectEqual(Transition.allowed, classify(.cancelling, .succeeded));
    try std.testing.expectEqual(Transition.allowed, classify(.cancelling, .cancelled));
    try std.testing.expectEqual(Transition.forbidden, classify(.cancelling, .running));
}

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    graph: Graph,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) void {
        fixture.* = .{
            .ids = .initDeterministic(4242),
            .manual = .init(.fromSeconds(1_000)),
            .graph = undefined,
            .human = .{ .value = 1 },
            .agent = .{ .value = 2 },
        };
        fixture.graph = .init(gpa, &fixture.ids, fixture.manual.clock());
    }

    fn deinit(fixture: *Fixture) void {
        fixture.graph.deinit();
    }

    fn root(fixture: *Fixture, purpose: []const u8) !identity.TaskId {
        return fixture.graph.create(.{
            .owner = fixture.human,
            .requester = fixture.human,
            .purpose = purpose,
            .budget_bytes = 1 << 16,
        });
    }

    fn child(
        fixture: *Fixture,
        parent: identity.TaskId,
        purpose: []const u8,
    ) !identity.TaskId {
        return fixture.graph.create(.{
            .owner = fixture.agent,
            .requester = fixture.human,
            .purpose = purpose,
            .parent = parent,
            .budget_bytes = 1 << 14,
        });
    }
};

test "a task graph records parentage and roots" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const calendar = try fixture.child(root, "inspect the calendar");
    const documents = try fixture.child(root, "retrieve local documents");

    try std.testing.expectEqual(@as(usize, 3), fixture.graph.count());
    try std.testing.expectEqual(@as(usize, 1), fixture.graph.roots.items.len);
    try std.testing.expectEqual(@as(usize, 2), fixture.graph.get(root).?.children.items.len);
    try std.testing.expect(fixture.graph.get(calendar).?.parent.eql(root));
    try std.testing.expect(fixture.graph.get(documents).?.parent.eql(root));
}

test "cancelling a root cancels its unfinished descendants" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const calendar = try fixture.child(root, "inspect the calendar");
    const travel = try fixture.child(root, "plan the route");
    const leg = try fixture.child(travel, "query the routing service");

    // One branch finishes before the cancellation.
    try fixture.graph.transition(calendar, .runnable);
    try fixture.graph.transition(calendar, .running);
    try fixture.graph.transition(calendar, .succeeded);

    const affected = try fixture.graph.cancel(root);

    try std.testing.expectEqual(State.succeeded, fixture.graph.get(calendar).?.state);
    try std.testing.expectEqual(State.cancelled, fixture.graph.get(root).?.state);
    try std.testing.expectEqual(State.cancelled, fixture.graph.get(travel).?.state);
    try std.testing.expectEqual(State.cancelled, fixture.graph.get(leg).?.state);
    try std.testing.expectEqual(@as(usize, 3), affected);
    try std.testing.expectEqual(@as(usize, 0), fixture.graph.unfinishedCount());
}

test "cancellation records which task caused it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const branch = try fixture.child(root, "plan the route");

    _ = try fixture.graph.cancel(root);

    switch (fixture.graph.get(branch).?.conclusion.?) {
        .cancelled_by => |cause| try std.testing.expect(cause.eql(root)),
        else => return error.TestUnexpectedResult,
    }
}

test "running work winds down rather than stopping instantly" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const branch = try fixture.child(root, "query the routing service");
    try fixture.graph.transition(branch, .runnable);
    try fixture.graph.transition(branch, .running);

    _ = try fixture.graph.cancel(root);

    // The task holds resources, so it must reach a cancellation point first.
    try std.testing.expectEqual(State.cancelling, fixture.graph.get(branch).?.state);
    try std.testing.expect(fixture.graph.get(branch).?.isCancellationRequested());

    try fixture.graph.completeCancellation(branch);
    try std.testing.expectEqual(State.cancelled, fixture.graph.get(branch).?.state);
}

test "work spawned during wind-down inherits the cancellation" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const branch = try fixture.child(root, "plan the route");
    try fixture.graph.transition(branch, .runnable);
    try fixture.graph.transition(branch, .running);

    _ = try fixture.graph.cancel(root);

    // A late child must not escape the cancellation by being created after it.
    const late = try fixture.child(branch, "follow-up query");
    try std.testing.expect(fixture.graph.get(late).?.isCancellationRequested());
}

test "a child cannot be attached to a finished parent" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    try fixture.graph.transition(root, .runnable);
    try fixture.graph.transition(root, .running);
    try fixture.graph.transition(root, .succeeded);

    try std.testing.expectError(error.Conflict, fixture.child(root, "orphan"));
}

test "detachment requires a complete new grant of authority" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const branch = try fixture.child(root, "index the documents");
    const owner: identity.PrincipalId = .{ .value = 9 };
    const expiry: time.Timestamp = .fromSeconds(5_000);

    try std.testing.expectError(error.InvalidInput, fixture.graph.detach(branch, .none, "indexing", 4096, expiry));
    try std.testing.expectError(error.InvalidInput, fixture.graph.detach(branch, owner, "", 4096, expiry));
    try std.testing.expectError(error.InvalidInput, fixture.graph.detach(branch, owner, "indexing", 0, expiry));
    try std.testing.expectError(error.InvalidInput, fixture.graph.detach(branch, owner, "indexing", 4096, .fromSeconds(500)));

    try fixture.graph.detach(branch, owner, "indexing", 4096, expiry);
    try std.testing.expect(fixture.graph.get(branch).?.detached);
}

test "a detached task survives its former parent's cancellation" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const attached = try fixture.child(root, "plan the route");
    const detached = try fixture.child(root, "index the documents");

    try fixture.graph.detach(
        detached,
        .{ .value = 9 },
        "maintain the document index",
        4096,
        .fromSeconds(5_000),
    );

    _ = try fixture.graph.cancel(root);

    try std.testing.expectEqual(State.cancelled, fixture.graph.get(attached).?.state);
    try std.testing.expectEqual(State.planned, fixture.graph.get(detached).?.state);
    try std.testing.expect(!fixture.graph.get(detached).?.isCancellationRequested());
}

test "a task already being cancelled cannot be detached out of the scope" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const branch = try fixture.child(root, "plan the route");

    _ = try fixture.graph.cancel(root);

    try std.testing.expectError(error.Conflict, fixture.graph.detach(
        branch,
        .{ .value = 9 },
        "escape",
        4096,
        .fromSeconds(5_000),
    ));
}

test "dependencies gate readiness and cycles are refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const first = try fixture.child(root, "inspect the calendar");
    const second = try fixture.child(root, "plan the route");

    try fixture.graph.addDependency(second, first);
    try std.testing.expect(!fixture.graph.dependenciesSatisfied(second));

    // A cycle would leave both permanently unrunnable.
    try std.testing.expectError(error.Conflict, fixture.graph.addDependency(first, second));
    try std.testing.expectError(error.InvalidInput, fixture.graph.addDependency(first, first));

    try fixture.graph.transition(first, .runnable);
    try fixture.graph.transition(first, .running);
    try fixture.graph.transition(first, .succeeded);
    try std.testing.expect(fixture.graph.dependenciesSatisfied(second));
}

test "a failed dependency leaves a dependent unsatisfied" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    const first = try fixture.child(root, "retrieve mail");
    const second = try fixture.child(root, "summarize mail");
    try fixture.graph.addDependency(second, first);

    try fixture.graph.fail(first, error.Unavailable);

    try std.testing.expect(!fixture.graph.dependenciesSatisfied(second));
    switch (fixture.graph.get(first).?.conclusion.?) {
        .failed_with => |reason| try std.testing.expectEqual(DomainError.Unavailable, reason),
        else => return error.TestUnexpectedResult,
    }
}

test "a duplicate transition after a restart changes nothing" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    try fixture.graph.transition(root, .runnable);
    try fixture.graph.transition(root, .running);
    try fixture.graph.transition(root, .succeeded);

    const attempts = fixture.graph.get(root).?.attempts_made;
    try fixture.graph.transition(root, .succeeded);

    try std.testing.expectEqual(State.succeeded, fixture.graph.get(root).?.state);
    try std.testing.expectEqual(attempts, fixture.graph.get(root).?.attempts_made);
}

test "a forbidden transition is refused without changing state" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    try std.testing.expectError(error.Conflict, fixture.graph.transition(root, .running));
    try std.testing.expectEqual(State.planned, fixture.graph.get(root).?.state);
}

test "cancelling an already finished task affects nothing" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    try fixture.graph.transition(root, .runnable);
    try fixture.graph.transition(root, .running);
    try fixture.graph.transition(root, .succeeded);

    try std.testing.expectEqual(@as(usize, 0), try fixture.graph.cancel(root));
}

test "cancellation visits only the subtree it is given" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const first_root = try fixture.root("prepare for the meeting");
    const first_branch = try fixture.child(first_root, "plan the route");
    const second_root = try fixture.root("index the mailbox");
    const second_branch = try fixture.child(second_root, "fetch headers");

    const affected = try fixture.graph.cancel(first_root);

    try std.testing.expectEqual(@as(usize, 2), affected);
    try std.testing.expectEqual(State.cancelled, fixture.graph.get(first_branch).?.state);
    try std.testing.expectEqual(State.planned, fixture.graph.get(second_root).?.state);
    try std.testing.expectEqual(State.planned, fixture.graph.get(second_branch).?.state);
}

test "a non-idempotent task is never retried automatically" {
    const unsafe: RetryPolicy = .{ .max_attempts = 5, .idempotent = false };
    try std.testing.expect(!unsafe.permitsRetry(0));

    const safe: RetryPolicy = .{ .max_attempts = 3, .idempotent = true };
    try std.testing.expect(safe.permitsRetry(0));
    try std.testing.expect(safe.permitsRetry(2));
    try std.testing.expect(!safe.permitsRetry(3));
}

test "a deadline is evaluated against the clock" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.graph.create(.{
        .owner = fixture.human,
        .requester = fixture.human,
        .purpose = "prepare for the meeting",
        .deadline = .fromSeconds(1_060),
        .budget_bytes = 4096,
    });

    try std.testing.expect(!fixture.graph.get(root).?.hasDeadlinePassed(fixture.manual.clock().wall()));
    fixture.manual.advance(.fromSeconds(120));
    try std.testing.expect(fixture.graph.get(root).?.hasDeadlinePassed(fixture.manual.clock().wall()));
}

test "a deep chain cancels completely" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.root("prepare for the meeting");
    var parent = root;
    for (0..32) |_| {
        parent = try fixture.child(parent, "descend");
    }

    const affected = try fixture.graph.cancel(root);
    try std.testing.expectEqual(@as(usize, 33), affected);
    try std.testing.expectEqual(@as(usize, 0), fixture.graph.unfinishedCount());
}
