//! Approval policy for consequential actions.
//!
//! An action is consequential when it reaches outside the system or cannot be
//! silently undone: sending a message, publishing, deleting durable data,
//! installing software, changing security settings, transferring value, sharing
//! private information, or granting authority.
//!
//! Consequential external actions require explicit approval by default. The
//! default is deliberate: a system that decides for itself when a human need
//! not be asked has already made the decision that matters.
//!
//! Approval produces authority that is narrow and spent. A decision authorizes
//! one action, once — not a standing permission to repeat it, and not a broader
//! grant that happens to cover it.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const outcome_model = @import("../base/outcome.zig");
const capability_model = @import("../capability/capability.zig");

const DomainError = outcome_model.DomainError;

/// What makes an action consequential. Recorded so an approval prompt can say
/// why it is being asked rather than only what is being asked.
pub const Consequence = enum {
    /// Reaches a party outside the device.
    external_communication,
    /// Makes content visible beyond its current audience.
    publication,
    /// Destroys durable state.
    destruction,
    /// Changes what code runs.
    software_change,
    /// Changes a security or privacy setting.
    security_change,
    /// Moves value.
    value_transfer,
    /// Discloses private information.
    disclosure,
    /// Creates authority for another principal.
    authority_grant,
    /// Reads or computes without lasting effect.
    none,

    /// Maps an operation onto the consequence it carries.
    pub fn ofOperation(operation: capability_model.Operation) Consequence {
        return switch (operation) {
            .read, .list => .none,
            .send => .external_communication,
            .publish => .publication,
            .delete => .destruction,
            .install => .software_change,
            .configure => .security_change,
            .transfer_value => .value_transfer,
            .grant => .authority_grant,
            .write, .create, .execute => .disclosure,
        };
    }

    pub fn isConsequential(consequence: Consequence) bool {
        return consequence != .none;
    }
};

/// How much human involvement an action requires.
pub const Requirement = enum {
    /// No approval; the action proceeds under existing authority.
    none,
    /// A human must approve this specific action before it runs.
    explicit_approval,
    /// A human must approve, and the approval expires quickly because the
    /// action's risk does not survive a stale decision.
    time_boxed_approval,

    pub fn requiresHuman(requirement: Requirement) bool {
        return requirement != .none;
    }
};

/// The rules that decide whether an action needs a human.
///
/// Defaults are restrictive. Loosening one is a deliberate configuration change
/// with its own audit record, never an inference the system makes on its own.
pub const Policy = struct {
    /// How long a time-boxed approval remains valid.
    approval_window: time.Duration = .{ .nanoseconds = 5 * std.time.ns_per_min },

    /// Consequences that may proceed without a human. Empty by default: every
    /// consequential action is held.
    permitted_without_approval: std.EnumSet(Consequence) = .initEmpty(),

    pub const strict: Policy = .{};

    /// What this action requires.
    ///
    /// Value transfer and authority grants are always time-boxed regardless of
    /// configuration: a stale decision to move money or widen authority is
    /// exactly the decision that should not be honored later.
    pub fn evaluate(policy: Policy, consequence: Consequence) Requirement {
        if (!consequence.isConsequential()) return .none;
        switch (consequence) {
            .value_transfer, .authority_grant => return .time_boxed_approval,
            else => {},
        }
        if (policy.permitted_without_approval.contains(consequence)) return .none;
        return .explicit_approval;
    }
};

pub const Decision = enum { approved, denied };

pub const State = enum {
    pending,
    approved,
    denied,
    expired,
    /// The approved action has run. Terminal, and the reason an approval
    /// cannot be replayed.
    spent,

    pub fn isTerminal(state: State) bool {
        return switch (state) {
            .denied, .expired, .spent => true,
            .pending, .approved => false,
        };
    }
};

/// A request for a human decision.
pub const Request = struct {
    id: identity.ApprovalId,
    /// The principal asking to act.
    requester: identity.PrincipalId,
    /// The human whose decision is required.
    approver: identity.PrincipalId,
    task: identity.TaskId,
    operation: capability_model.Operation,
    consequence: Consequence,
    requirement: Requirement,
    /// What the action is directed at, in the domain's terms.
    target_kind: []const u8,
    /// A bounded description of what will happen, for the human to read.
    summary: []const u8,
    requested_at: time.Timestamp,
    /// When a time-boxed approval stops being valid.
    expires_at: ?time.Timestamp,
    state: State,
    decided_at: ?time.Timestamp,
};

/// What a caller supplies to open a request.
pub const Submission = struct {
    requester: identity.PrincipalId,
    approver: identity.PrincipalId,
    task: identity.TaskId,
    operation: capability_model.Operation,
    target_kind: []const u8,
    summary: []const u8,
};

/// Longest description shown to a human. A prompt long enough to hide its own
/// meaning is a dark pattern, so the length is bounded at the boundary.
pub const max_summary_bytes: usize = 512;

/// Outstanding and settled approval requests.
///
/// Ownership: the centre owns its requests and the strings it copies from each
/// submission. `deinit` releases both.
pub const Centre = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    clock: time.Clock,
    policy: Policy,
    requests: std.AutoHashMapUnmanaged(u128, Request) = .empty,
    owned_text: std.ArrayList([]const u8) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        ids: *identity.Source,
        clock: time.Clock,
        policy: Policy,
    ) Centre {
        return .{ .gpa = gpa, .ids = ids, .clock = clock, .policy = policy };
    }

    pub fn deinit(centre: *Centre) void {
        for (centre.owned_text.items) |text| centre.gpa.free(text);
        centre.owned_text.deinit(centre.gpa);
        centre.requests.deinit(centre.gpa);
        centre.* = undefined;
    }

    fn ownText(centre: *Centre, text: []const u8) ![]const u8 {
        const copy = try centre.gpa.dupe(u8, text);
        errdefer centre.gpa.free(copy);
        try centre.owned_text.append(centre.gpa, copy);
        return copy;
    }

    /// Opens a request for a human decision.
    ///
    /// Refuses an action that needs no approval, so a caller cannot manufacture
    /// a prompt to make a routine action look sanctioned.
    pub fn request(centre: *Centre, submission: Submission) !identity.ApprovalId {
        if (submission.summary.len == 0) return error.InvalidInput;
        if (submission.summary.len > max_summary_bytes) return error.InvalidInput;
        if (submission.approver.isNone()) return error.InvalidInput;

        const consequence: Consequence = .ofOperation(submission.operation);
        const requirement = centre.policy.evaluate(consequence);
        if (!requirement.requiresHuman()) return error.InvalidInput;

        const now = centre.clock.wall();
        const id = centre.ids.next(identity.ApprovalId);

        try centre.requests.put(centre.gpa, id.value, .{
            .id = id,
            .requester = submission.requester,
            .approver = submission.approver,
            .task = submission.task,
            .operation = submission.operation,
            .consequence = consequence,
            .requirement = requirement,
            .target_kind = try centre.ownText(submission.target_kind),
            .summary = try centre.ownText(submission.summary),
            .requested_at = now,
            .expires_at = if (requirement == .time_boxed_approval)
                now.plus(centre.policy.approval_window)
            else
                null,
            .state = .pending,
            .decided_at = null,
        });
        return id;
    }

    pub fn get(centre: Centre, id: identity.ApprovalId) ?Request {
        return centre.requests.get(id.value);
    }

    /// Records a human's decision.
    ///
    /// Only the named approver may decide, and only once. A second decision on
    /// a settled request is refused rather than overwriting the first.
    pub fn decide(
        centre: *Centre,
        id: identity.ApprovalId,
        approver: identity.PrincipalId,
        decision: Decision,
    ) DomainError!void {
        const entry = centre.requests.getPtr(id.value) orelse return error.InvalidInput;
        if (!entry.approver.eql(approver)) return error.Unauthorized;
        if (entry.state.isTerminal()) return error.Conflict;
        if (entry.state == .approved) return error.Conflict;

        const now = centre.clock.wall();
        if (entry.expires_at) |expiry| {
            if (!expiry.isAfter(now)) {
                entry.state = .expired;
                return error.CapabilityExpired;
            }
        }

        entry.state = switch (decision) {
            .approved => .approved,
            .denied => .denied,
        };
        entry.decided_at = now;
    }

    /// Confirms an approval is still good and marks it spent.
    ///
    /// This is what makes an approved action execute exactly once: the first
    /// call consumes the approval, and every later call finds it spent. An
    /// expired approval is refused even though it was granted, because the
    /// decision was made about a moment that has passed.
    pub fn consume(
        centre: *Centre,
        id: identity.ApprovalId,
        requester: identity.PrincipalId,
    ) DomainError!Request {
        const entry = centre.requests.getPtr(id.value) orelse return error.InvalidInput;
        if (!entry.requester.eql(requester)) return error.Unauthorized;

        switch (entry.state) {
            .pending => return error.Unauthorized,
            .denied => return error.Unauthorized,
            .expired => return error.CapabilityExpired,
            .spent => return error.Conflict,
            .approved => {},
        }

        const now = centre.clock.wall();
        if (entry.expires_at) |expiry| {
            if (!expiry.isAfter(now)) {
                entry.state = .expired;
                return error.CapabilityExpired;
            }
        }

        entry.state = .spent;
        return entry.*;
    }

    /// Marks every time-boxed approval whose window has closed.
    ///
    /// Returns how many expired. Expiry is also checked at use, so this is for
    /// keeping the approval surface honest rather than for correctness.
    pub fn expireStale(centre: *Centre) usize {
        const now = centre.clock.wall();
        var expired: usize = 0;
        var iterator = centre.requests.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.state.isTerminal()) continue;
            const expiry = entry.expires_at orelse continue;
            if (!expiry.isAfter(now)) {
                entry.state = .expired;
                expired += 1;
            }
        }
        return expired;
    }

    pub fn pendingCount(centre: Centre) usize {
        var pending: usize = 0;
        var iterator = centre.requests.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.state == .pending) pending += 1;
        }
        return pending;
    }
};

/// The constraints an approved action's capability must carry.
///
/// Approval grants narrow, spent authority: bound to the task that asked, valid
/// once, and requiring the human confirmation that just occurred. Building the
/// constraints here rather than at each call site means no caller can widen
/// them by omission.
pub fn constraintsForApproval(request: Request, expires_at: ?time.Timestamp) capability_model.Constraints {
    return .{
        .one_time = true,
        .invocation_limit = 1,
        .requires_human_confirmation = true,
        .task_binding = request.task,
        .delegation_depth = 0,
        .expires_at = expires_at orelse request.expires_at,
        .revocation_behavior = .prevent_next_step,
    };
}

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    centre: Centre,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,
    task: identity.TaskId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture, policy: Policy) void {
        fixture.* = .{
            .ids = .initDeterministic(8080),
            .manual = .init(.fromSeconds(1_000)),
            .centre = undefined,
            .human = .{ .value = 1 },
            .agent = .{ .value = 2 },
            .task = .{ .value = 3 },
        };
        fixture.centre = .init(gpa, &fixture.ids, fixture.manual.clock(), policy);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.centre.deinit();
    }

    fn submit(fixture: *Fixture, operation: capability_model.Operation) !identity.ApprovalId {
        return fixture.centre.request(.{
            .requester = fixture.agent,
            .approver = fixture.human,
            .task = fixture.task,
            .operation = operation,
            .target_kind = "message",
            .summary = "send a confirmation to the venue",
        });
    }
};

test "reads need no approval and every consequential operation does" {
    const policy: Policy = .strict;
    for (std.enums.values(capability_model.Operation)) |operation| {
        const consequence: Consequence = .ofOperation(operation);
        const requirement = policy.evaluate(consequence);
        try std.testing.expectEqual(operation.isConsequential(), requirement.requiresHuman());
    }
}

test "value transfer and authority grants are always time-boxed" {
    // Even a policy that permits everything without approval must not relax
    // these: a stale decision to move value or widen authority is the decision
    // that must not be honored later.
    var permissive: Policy = .{};
    for (std.enums.values(Consequence)) |consequence| {
        permissive.permitted_without_approval.insert(consequence);
    }

    try std.testing.expectEqual(Requirement.time_boxed_approval, permissive.evaluate(.value_transfer));
    try std.testing.expectEqual(Requirement.time_boxed_approval, permissive.evaluate(.authority_grant));
    try std.testing.expectEqual(Requirement.none, permissive.evaluate(.external_communication));
}

test "an approved action executes exactly once" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.submit(.send);
    try fixture.centre.decide(id, fixture.human, .approved);

    _ = try fixture.centre.consume(id, fixture.agent);

    // The second attempt finds the approval spent.
    try std.testing.expectError(error.Conflict, fixture.centre.consume(id, fixture.agent));
    try std.testing.expectEqual(State.spent, fixture.centre.get(id).?.state);
}

test "an unapproved request cannot be consumed" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.submit(.send);
    try std.testing.expectError(error.Unauthorized, fixture.centre.consume(id, fixture.agent));
    try std.testing.expectEqual(@as(usize, 1), fixture.centre.pendingCount());
}

test "a denied request cannot be consumed and cannot be reversed" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.submit(.send);
    try fixture.centre.decide(id, fixture.human, .denied);

    try std.testing.expectError(error.Unauthorized, fixture.centre.consume(id, fixture.agent));
    try std.testing.expectError(error.Conflict, fixture.centre.decide(id, fixture.human, .approved));
}

test "only the named approver may decide" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.submit(.send);
    const impostor: identity.PrincipalId = .{ .value = 77 };

    try std.testing.expectError(error.Unauthorized, fixture.centre.decide(id, impostor, .approved));
    try std.testing.expectEqual(State.pending, fixture.centre.get(id).?.state);
}

test "only the requester may consume its own approval" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.submit(.send);
    try fixture.centre.decide(id, fixture.human, .approved);

    const other_agent: identity.PrincipalId = .{ .value = 88 };
    try std.testing.expectError(error.Unauthorized, fixture.centre.consume(id, other_agent));

    // The approval survives the failed attempt for its rightful holder.
    _ = try fixture.centre.consume(id, fixture.agent);
}

test "a decision cannot be made twice" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.submit(.send);
    try fixture.centre.decide(id, fixture.human, .approved);
    try std.testing.expectError(error.Conflict, fixture.centre.decide(id, fixture.human, .denied));
}

test "a time-boxed approval expires before it is used" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.centre.request(.{
        .requester = fixture.agent,
        .approver = fixture.human,
        .task = fixture.task,
        .operation = .transfer_value,
        .target_kind = "payment",
        .summary = "pay the deposit",
    });
    try fixture.centre.decide(id, fixture.human, .approved);

    fixture.manual.advance(.fromSeconds(600));

    try std.testing.expectError(error.CapabilityExpired, fixture.centre.consume(id, fixture.agent));
    try std.testing.expectEqual(State.expired, fixture.centre.get(id).?.state);
}

test "a decision on an already expired request is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.centre.request(.{
        .requester = fixture.agent,
        .approver = fixture.human,
        .task = fixture.task,
        .operation = .grant,
        .target_kind = "capability",
        .summary = "grant calendar access to the travel agent",
    });

    fixture.manual.advance(.fromSeconds(600));
    try std.testing.expectError(error.CapabilityExpired, fixture.centre.decide(id, fixture.human, .approved));
    try std.testing.expectEqual(State.expired, fixture.centre.get(id).?.state);
}

test "stale approvals are swept from the pending surface" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    _ = try fixture.centre.request(.{
        .requester = fixture.agent,
        .approver = fixture.human,
        .task = fixture.task,
        .operation = .transfer_value,
        .target_kind = "payment",
        .summary = "pay the deposit",
    });
    _ = try fixture.submit(.send);

    try std.testing.expectEqual(@as(usize, 2), fixture.centre.pendingCount());

    fixture.manual.advance(.fromSeconds(600));

    // Only the time-boxed one expires; the open-ended one still awaits a human.
    try std.testing.expectEqual(@as(usize, 1), fixture.centre.expireStale());
    try std.testing.expectEqual(@as(usize, 1), fixture.centre.pendingCount());
}

test "a prompt cannot be manufactured for a routine action" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    // Making a read look sanctioned by wrapping it in an approval is refused.
    try std.testing.expectError(error.InvalidInput, fixture.submit(.read));
    try std.testing.expectError(error.InvalidInput, fixture.submit(.list));
}

test "a request must carry a bounded description a human can read" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    try std.testing.expectError(error.InvalidInput, fixture.centre.request(.{
        .requester = fixture.agent,
        .approver = fixture.human,
        .task = fixture.task,
        .operation = .send,
        .target_kind = "message",
        .summary = "",
    }));

    const overlong: [max_summary_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidInput, fixture.centre.request(.{
        .requester = fixture.agent,
        .approver = fixture.human,
        .task = fixture.task,
        .operation = .send,
        .target_kind = "message",
        .summary = &overlong,
    }));
}

test "a request must name a human to decide it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    try std.testing.expectError(error.InvalidInput, fixture.centre.request(.{
        .requester = fixture.agent,
        .approver = .none,
        .task = fixture.task,
        .operation = .send,
        .target_kind = "message",
        .summary = "send a confirmation to the venue",
    }));
}

test "approval yields narrow, task-bound, single-use authority" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture, .strict);
    defer fixture.deinit();

    const id = try fixture.submit(.send);
    try fixture.centre.decide(id, fixture.human, .approved);
    const approved = try fixture.centre.consume(id, fixture.agent);

    const constraints = constraintsForApproval(approved, .fromSeconds(1_100));

    try std.testing.expect(constraints.one_time);
    try std.testing.expectEqual(@as(?u32, 1), constraints.invocation_limit);
    try std.testing.expect(constraints.requires_human_confirmation);
    try std.testing.expect(constraints.task_binding.eql(fixture.task));
    try std.testing.expectEqual(@as(u8, 0), constraints.delegation_depth);
}

test "policy loosening is explicit and never inferred" {
    var policy: Policy = .strict;
    try std.testing.expectEqual(Requirement.explicit_approval, policy.evaluate(.external_communication));

    policy.permitted_without_approval.insert(.external_communication);
    try std.testing.expectEqual(Requirement.none, policy.evaluate(.external_communication));

    // Loosening one consequence must not loosen any other.
    try std.testing.expectEqual(Requirement.explicit_approval, policy.evaluate(.destruction));
    try std.testing.expectEqual(Requirement.explicit_approval, policy.evaluate(.publication));
}
