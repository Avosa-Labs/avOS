//! The control plane assembled for a deterministic run.
//!
//! This is the first implementation target: the principal, capability, task,
//! resource, audit, and policy models running together on a development machine
//! with no device, no compatibility runtime, and no network. Everything that
//! would vary between runs — the clock, identifiers, model answers, connector
//! responses, failures — is supplied, so a scenario produces the same result on
//! every machine and can be compared against a previous run.
//!
//! The host owns the services and lends them to a scenario. It performs no work
//! of its own: a scenario drives it, and every privileged step goes through the
//! same checks a real caller would face.

const std = @import("std");
const core = @import("core");
const model = @import("../model/model.zig");

const identity = core.identity;
const time = core.time;
const principal_model = core.principal;
const capability_model = core.capability;
const task_model = core.task;
const audit = core.audit;
const policy_model = core.policy;
const resource = core.resource;

const DomainError = core.outcome.DomainError;

pub const Options = struct {
    /// Seed for identifier issue. Two runs with the same seed produce the same
    /// identifiers, which is what makes a replay comparable.
    seed: u64 = 20260722,
    /// Wall-clock instant the run begins at.
    start: time.Timestamp = .fromSeconds(1_767_225_600),
    approval_policy: policy_model.Policy = .strict,
    /// Ceiling for each agent task's budget.
    agent_budget_bytes: usize = 64 * 1024,
};

/// One agent participating in a run, with the authority it was given.
pub const Agent = struct {
    id: identity.PrincipalId,
    name: []const u8,
    /// Handles this agent holds. Held by the host, not by the agent, because a
    /// simulated agent has no address space of its own.
    handles: std.ArrayList(capability_model.Handle) = .empty,
    /// The task this agent's branch runs under.
    task: identity.TaskId = .none,
    /// Memory budget for this agent's branch.
    budget: resource.Budget = undefined,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal_model.Registry,
    capabilities: capability_model.Store,
    graph: task_model.Graph,
    ledger: audit.Ledger,
    approvals: policy_model.Centre,
    options: Options,
    /// Agents are held by pointer so that enrolling another one does not move
    /// the ones already handed out. The host owns each record and releases it
    /// in `deinit`.
    agents: std.ArrayList(*Agent) = .empty,
    human: identity.PrincipalId = .none,

    /// Initializes in place. The services hold pointers into the host, so the
    /// host must not be copied after this returns.
    pub fn init(host: *Host, gpa: std.mem.Allocator, options: Options) void {
        host.* = .{
            .gpa = gpa,
            .ids = .initDeterministic(options.seed),
            .manual = .init(options.start),
            .registry = undefined,
            .capabilities = undefined,
            .graph = undefined,
            .ledger = undefined,
            .approvals = undefined,
            .options = options,
        };
        const shared_clock = host.manual.clock();
        host.registry = .init(gpa, &host.ids, shared_clock);
        host.capabilities = .init(gpa, &host.ids, shared_clock, &host.registry);
        host.graph = .init(gpa, &host.ids, shared_clock);
        host.ledger = .init(gpa, &host.ids, shared_clock);
        host.approvals = .init(gpa, &host.ids, shared_clock, options.approval_policy);
    }

    pub fn deinit(host: *Host) void {
        for (host.agents.items) |agent| {
            agent.handles.deinit(host.gpa);
            host.gpa.destroy(agent);
        }
        host.agents.deinit(host.gpa);
        host.approvals.deinit();
        host.ledger.deinit();
        host.graph.deinit();
        host.capabilities.deinit();
        host.registry.deinit();
        host.* = undefined;
    }

    pub fn clock(host: *Host) time.Clock {
        return host.manual.clock();
    }

    pub fn now(host: *Host) time.Timestamp {
        return host.manual.clock().wall();
    }

    /// Enrolls the human whose authority the run originates from.
    pub fn authenticateHuman(host: *Host, display_name: []const u8) !identity.PrincipalId {
        const id = try host.registry.enroll(.{
            .kind = .human,
            .display_name = display_name,
            .policy_domain = "local",
        });
        host.human = id;
        _ = try host.ledger.append(.{
            .actor = id,
            .action = .authenticated,
            .outcome = .succeeded,
            .provenance = .human_input,
        });
        return id;
    }

    /// Enrolls an agent acting for the authenticated human.
    pub fn enrollAgent(
        host: *Host,
        name: []const u8,
        expires_in: time.Duration,
    ) !*Agent {
        const id = try host.registry.enroll(.{
            .kind = .agent,
            .display_name = name,
            .policy_domain = "local",
            .expires_at = host.now().plus(expires_in),
            .issuer = host.human,
        });
        _ = try host.ledger.append(.{
            .actor = id,
            .on_behalf_of = host.human,
            .action = .principal_created,
            .outcome = .succeeded,
        });

        const agent = try host.gpa.create(Agent);
        errdefer host.gpa.destroy(agent);
        agent.* = .{
            .id = id,
            .name = name,
            .budget = .init(host.gpa, host.options.agent_budget_bytes, .{
                .principal = id,
                .task = .none,
            }),
        };
        try host.agents.append(host.gpa, agent);
        return agent;
    }

    pub fn agentNamed(host: *Host, name: []const u8) ?*Agent {
        for (host.agents.items) |agent| {
            if (std.mem.eql(u8, agent.name, name)) return agent;
        }
        return null;
    }

    /// Issues a grant from the human to an agent and records it.
    pub fn grant(
        host: *Host,
        agent: *Agent,
        resource_kind: []const u8,
        operations: capability_model.OperationSet,
        constraints: capability_model.Constraints,
    ) !capability_model.Handle {
        const handle = try host.capabilities.issue(.{
            .issuer = host.human,
            .holder = agent.id,
            .resource = .{ .kind = resource_kind },
            .operations = operations,
            .constraints = constraints,
        });
        try agent.handles.append(host.gpa, handle);
        _ = try host.ledger.append(.{
            .actor = host.human,
            .on_behalf_of = agent.id,
            .action = .capability_issued,
            .outcome = .succeeded,
            .capability = handle.id,
            .target_kind = resource_kind,
        });
        return handle;
    }

    /// Attempts an operation on an agent's behalf and records the result.
    ///
    /// Every attempt is recorded, whether it succeeds or is refused. A denial
    /// that left no trace would be invisible to the person the system is meant
    /// to be accountable to.
    pub fn attempt(
        host: *Host,
        agent: *Agent,
        handle: capability_model.Handle,
        context: capability_model.UseContext,
        data_movement: audit.DataMovement,
        /// The event that caused this attempt, linking it into a causal chain.
        caused_by: identity.AuditEventId,
    ) DomainError!capability_model.Capability {
        const used = host.capabilities.use(handle, context) catch |refusal| {
            _ = host.ledger.append(.{
                .actor = agent.id,
                .on_behalf_of = host.human,
                .action = .action_denied,
                .outcome = .denied,
                .refusal = refusal,
                .task = context.task,
                .capability = handle.id,
                .target_kind = context.resource.kind,
                .data_movement = .not_applicable,
                .parent = caused_by,
            }) catch return error.InternalFault;
            return refusal;
        };

        _ = host.ledger.append(.{
            .actor = agent.id,
            .on_behalf_of = host.human,
            .action = .capability_used,
            .outcome = .succeeded,
            .task = context.task,
            .capability = handle.id,
            .target_kind = context.resource.kind,
            .data_movement = data_movement,
            .parent = caused_by,
        }) catch return error.InternalFault;
        return used;
    }

    /// Records a model invocation. Only metadata is recorded: the prompt and
    /// the answer are never written to the ledger.
    pub fn recordModelInvocation(
        host: *Host,
        agent: *Agent,
        adapter: *const model.Adapter,
        task: identity.TaskId,
        commentary: []const u8,
    ) !identity.AuditEventId {
        return host.ledger.append(.{
            .actor = agent.id,
            .on_behalf_of = host.human,
            .action = .model_invoked,
            .outcome = .succeeded,
            .task = task,
            .provenance = .model_output,
            .data_movement = if (adapter.runs_locally) .stayed_local else .left_device,
            .content = .of(commentary),
        });
    }

    /// Total bytes currently held across every agent budget. A completed or
    /// cancelled run must return this to its starting value.
    pub fn liveAgentBytes(host: *Host) usize {
        var total: usize = 0;
        for (host.agents.items) |agent| total += agent.budget.usage.current_bytes;
        return total;
    }

    /// Peak bytes reached across every agent budget.
    pub fn peakAgentBytes(host: *Host) usize {
        var total: usize = 0;
        for (host.agents.items) |agent| total += agent.budget.usage.peak_bytes;
        return total;
    }

    pub fn allAgentBudgetsBalanced(host: *Host) bool {
        for (host.agents.items) |agent| {
            if (!agent.budget.isBalanced()) return false;
        }
        return true;
    }
};

test "a host assembles a working control plane" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    const human = try host.authenticateHuman("operator");
    try std.testing.expect(!human.isNone());
    try std.testing.expectEqual(@as(usize, 1), host.ledger.count());
    try std.testing.expectEqual(audit.Action.authenticated, host.ledger.at(0).?.action);
}

test "two runs with the same seed produce identical identifiers" {
    const gpa = std.testing.allocator;

    var first: Host = undefined;
    Host.init(&first, gpa, .{ .seed = 99 });
    defer first.deinit();
    const first_human = try first.authenticateHuman("operator");

    var second: Host = undefined;
    Host.init(&second, gpa, .{ .seed = 99 });
    defer second.deinit();
    const second_human = try second.authenticateHuman("operator");

    try std.testing.expect(first_human.eql(second_human));
}

test "an agent is enrolled with an expiry and its own budget" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    _ = try host.authenticateHuman("operator");
    const agent = try host.enrollAgent("calendar", .fromSeconds(3_600));

    const record = host.registry.lookup(agent.id).?;
    try std.testing.expectEqual(principal_model.Kind.agent, record.kind);
    try std.testing.expect(record.expires_at != null);
    try std.testing.expect(agent.budget.isBalanced());
}

test "a denied attempt is recorded with its reason" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    _ = try host.authenticateHuman("operator");
    const agent = try host.enrollAgent("calendar", .fromSeconds(3_600));

    var read_only: capability_model.OperationSet = .initEmpty();
    read_only.insert(.read);
    const handle = try host.grant(agent, "calendar", read_only, .{});

    const refused = host.attempt(agent, handle, .{
        .holder = agent.id,
        .operation = .delete,
        .resource = .{ .kind = "calendar" },
    }, .not_applicable, .none);
    try std.testing.expectError(error.Unauthorized, refused);

    const denials = try host.ledger.denials(gpa);
    defer gpa.free(denials);
    try std.testing.expectEqual(@as(usize, 1), denials.len);
    try std.testing.expectEqual(core.outcome.DomainError.Unauthorized, denials[0].refusal.?);
}

test "a model invocation records metadata and never the text" {
    const gpa = std.testing.allocator;
    var host: Host = undefined;
    Host.init(&host, gpa, .{});
    defer host.deinit();

    _ = try host.authenticateHuman("operator");
    const agent = try host.enrollAgent("planner", .fromSeconds(3_600));

    var adapter: model.Adapter = .{
        .model_name = "reference-planner",
        .runs_locally = true,
        .answers = &.{},
    };

    const secret_commentary = "the private contents of the plan";
    const event_id = try host.recordModelInvocation(agent, &adapter, .none, secret_commentary);
    const event = host.ledger.find(event_id).?;

    try std.testing.expectEqual(audit.Provenance.model_output, event.provenance);
    try std.testing.expectEqual(audit.DataMovement.stayed_local, event.data_movement);
    // Only a digest of the commentary is retained.
    try std.testing.expect(event.content.?.eql(audit.ContentDigest.of(secret_commentary)));
}
