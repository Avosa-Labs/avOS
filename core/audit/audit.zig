//! The activity ledger.
//!
//! Privileged activity is observable while it happens and reconstructable
//! afterwards. The ledger answers what acted, for whom, why, under which
//! authority, on which data, whether anything left the device, and what
//! changed — from records, never from a summary generated after the fact.
//!
//! The ledger is deliberately not a copy of the user's data. It records the
//! shape of an action: type, resource identifier, authority, outcome, and a
//! digest of any content involved. It does not record message bodies, prompts,
//! documents, model context, or credentials. A ledger that accumulated those
//! would become the most valuable target on the device while adding nothing to
//! the explanation it exists to give.
//!
//! Appends are amortized constant time. Recording is on the path of every
//! privileged operation, so it cannot be proportional to history.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const outcome_model = @import("../base/outcome.zig");

const Outcome = outcome_model.Outcome;
const DomainError = outcome_model.DomainError;

/// What happened. Every privileged operation maps onto one of these.
pub const Action = enum {
    authenticated,
    principal_created,
    principal_revoked,
    capability_issued,
    capability_delegated,
    capability_used,
    capability_expired,
    capability_revoked,
    task_created,
    task_transitioned,
    task_cancelled,
    task_completed,
    model_invoked,
    tool_invoked,
    action_denied,
    approval_requested,
    approval_decided,
    package_installed,
    package_removed,
    policy_changed,
    endpoint_connected,
    endpoint_revoked,
    update_attempted,
    integrity_failed,
    resource_limit_breached,

    /// Whether an event of this kind must name the authority under which it
    /// occurred. An action taken under a capability is unexplainable without it.
    pub fn requiresCapability(action: Action) bool {
        return switch (action) {
            .capability_used, .capability_delegated, .capability_revoked => true,
            else => false,
        };
    }
};

/// Where a recorded fact came from, so a reader can tell an observation from an
/// inference.
pub const Provenance = enum {
    /// Observed directly by the control plane.
    control_plane,
    /// Reported by a human principal.
    human_input,
    /// Returned by a model. Never a verified fact on its own.
    model_output,
    /// Returned by an external service through a connector.
    external_service,
    /// Read from local durable state.
    local_state,
    /// Produced by a compatibility runtime.
    compatibility_runtime,

    /// Whether a fact from this source may be treated as verified without
    /// further validation.
    pub fn isTrustworthy(provenance: Provenance) bool {
        return switch (provenance) {
            .control_plane, .local_state => true,
            .human_input, .model_output, .external_service, .compatibility_runtime => false,
        };
    }
};

/// Whether data left the device to satisfy an action. Recorded on every event
/// so the question can be answered without inspecting connector logs.
pub const DataMovement = enum {
    stayed_local,
    left_device,
    not_applicable,
};

/// A bounded, non-reversible reference to content.
///
/// The ledger stores this instead of the content itself: it is enough to prove
/// two records refer to the same thing, and to detect that something changed,
/// without retaining what it was.
pub const ContentDigest = struct {
    bytes: [32]u8,

    pub fn of(content: []const u8) ContentDigest {
        var digest: ContentDigest = .{ .bytes = undefined };
        std.crypto.hash.sha2.Sha256.hash(content, &digest.bytes, .{});
        return digest;
    }

    pub fn eql(digest: ContentDigest, other: ContentDigest) bool {
        return std.mem.eql(u8, &digest.bytes, &other.bytes);
    }

    pub fn format(digest: ContentDigest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{x}", .{digest.bytes});
    }
};

pub const Event = struct {
    id: identity.AuditEventId,
    sequence: u64,
    timestamp: time.Timestamp,
    /// The principal that acted.
    actor: identity.PrincipalId,
    /// The principal the actor acted for, when different.
    on_behalf_of: identity.PrincipalId,
    task: identity.TaskId,
    capability: identity.CapabilityId,
    action: Action,
    /// What the action was directed at.
    target: identity.ResourceId,
    /// The kind of the target, in the domain's terms.
    target_kind: []const u8,
    outcome: Outcome,
    /// Present when the outcome was a denial or failure.
    refusal: ?DomainError,
    provenance: Provenance,
    data_movement: DataMovement,
    /// Digest of any content involved. Never the content.
    content: ?ContentDigest,
    /// The event that caused this one, linking a chain of consequences.
    parent: identity.AuditEventId,
};

/// What a caller supplies to record an event. The ledger assigns identity,
/// sequence, and timestamp so they cannot be forged by the caller.
pub const Record = struct {
    actor: identity.PrincipalId,
    action: Action,
    outcome: Outcome,
    on_behalf_of: identity.PrincipalId = .none,
    task: identity.TaskId = .none,
    capability: identity.CapabilityId = .none,
    target: identity.ResourceId = .none,
    target_kind: []const u8 = "",
    refusal: ?DomainError = null,
    provenance: Provenance = .control_plane,
    data_movement: DataMovement = .not_applicable,
    content: ?ContentDigest = null,
    parent: identity.AuditEventId = .none,
};

/// Append-only record of privileged activity.
///
/// Ownership: the ledger owns its events and the target-kind strings it copies.
/// `deinit` releases both. Events are never mutated after append and never
/// removed, so a reader holding an index sees a stable record.
pub const Ledger = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    clock: time.Clock,
    events: std.ArrayList(Event) = .empty,
    owned_text: std.ArrayList([]const u8) = .empty,
    next_sequence: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, ids: *identity.Source, clock: time.Clock) Ledger {
        return .{ .gpa = gpa, .ids = ids, .clock = clock };
    }

    pub fn deinit(ledger: *Ledger) void {
        for (ledger.owned_text.items) |text| ledger.gpa.free(text);
        ledger.owned_text.deinit(ledger.gpa);
        ledger.events.deinit(ledger.gpa);
        ledger.* = undefined;
    }

    /// Appends an event and returns its identifier.
    ///
    /// The sequence number is assigned here and increases by one for every
    /// event, so a gap in the sequence is evidence that the ledger was
    /// truncated rather than merely quiet.
    pub fn append(ledger: *Ledger, record: Record) !identity.AuditEventId {
        const id = ledger.ids.next(identity.AuditEventId);

        const target_kind = if (record.target_kind.len == 0)
            ""
        else blk: {
            const copy = try ledger.gpa.dupe(u8, record.target_kind);
            errdefer ledger.gpa.free(copy);
            try ledger.owned_text.append(ledger.gpa, copy);
            break :blk copy;
        };

        try ledger.events.append(ledger.gpa, .{
            .id = id,
            .sequence = ledger.next_sequence,
            .timestamp = ledger.clock.wall(),
            .actor = record.actor,
            .on_behalf_of = record.on_behalf_of,
            .task = record.task,
            .capability = record.capability,
            .action = record.action,
            .target = record.target,
            .target_kind = target_kind,
            .outcome = record.outcome,
            .refusal = record.refusal,
            .provenance = record.provenance,
            .data_movement = record.data_movement,
            .content = record.content,
            .parent = record.parent,
        });
        ledger.next_sequence += 1;
        return id;
    }

    pub fn count(ledger: Ledger) usize {
        return ledger.events.items.len;
    }

    pub fn at(ledger: Ledger, index: usize) ?Event {
        if (index >= ledger.events.items.len) return null;
        return ledger.events.items[index];
    }

    pub fn find(ledger: Ledger, id: identity.AuditEventId) ?Event {
        for (ledger.events.items) |event| {
            if (event.id.eql(id)) return event;
        }
        return null;
    }

    /// Every event belonging to one task, in the order it was recorded.
    ///
    /// Caller owns the returned slice.
    pub fn eventsForTask(
        ledger: Ledger,
        gpa: std.mem.Allocator,
        task: identity.TaskId,
    ) ![]Event {
        var collected: std.ArrayList(Event) = .empty;
        errdefer collected.deinit(gpa);
        for (ledger.events.items) |event| {
            if (event.task.eql(task)) try collected.append(gpa, event);
        }
        return collected.toOwnedSlice(gpa);
    }

    /// Every event recorded for one actor. Caller owns the returned slice.
    pub fn eventsForActor(
        ledger: Ledger,
        gpa: std.mem.Allocator,
        actor: identity.PrincipalId,
    ) ![]Event {
        var collected: std.ArrayList(Event) = .empty;
        errdefer collected.deinit(gpa);
        for (ledger.events.items) |event| {
            if (event.actor.eql(actor)) try collected.append(gpa, event);
        }
        return collected.toOwnedSlice(gpa);
    }

    /// Every denial recorded. Caller owns the returned slice.
    pub fn denials(ledger: Ledger, gpa: std.mem.Allocator) ![]Event {
        var collected: std.ArrayList(Event) = .empty;
        errdefer collected.deinit(gpa);
        for (ledger.events.items) |event| {
            if (event.outcome == .denied) try collected.append(gpa, event);
        }
        return collected.toOwnedSlice(gpa);
    }

    /// Whether anything recorded here left the device.
    pub fn anyDataLeftDevice(ledger: Ledger) bool {
        for (ledger.events.items) |event| {
            if (event.data_movement == .left_device) return true;
        }
        return false;
    }

    /// Confirms the sequence is unbroken and strictly increasing.
    ///
    /// A ledger that fails this has lost events, whatever else it contains.
    pub fn verifySequence(ledger: Ledger) bool {
        var expected: u64 = 1;
        for (ledger.events.items) |event| {
            if (event.sequence != expected) return false;
            expected += 1;
        }
        return true;
    }

    /// Follows the causal chain back from an event to its first cause.
    ///
    /// Caller owns the returned slice, ordered from the first cause to `id`.
    pub fn causalChain(
        ledger: Ledger,
        gpa: std.mem.Allocator,
        id: identity.AuditEventId,
    ) ![]Event {
        var reversed: std.ArrayList(Event) = .empty;
        defer reversed.deinit(gpa);

        var current = id;
        // The chain cannot be longer than the ledger, which bounds the walk
        // even if a parent reference were ever to form a cycle.
        var remaining = ledger.events.items.len + 1;
        while (!current.isNone() and remaining > 0) : (remaining -= 1) {
            const event = ledger.find(current) orelse break;
            try reversed.append(gpa, event);
            current = event.parent;
        }

        const chain = try gpa.alloc(Event, reversed.items.len);
        for (reversed.items, 0..) |event, index| {
            chain[chain.len - 1 - index] = event;
        }
        return chain;
    }
};

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    ledger: Ledger,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,
    task: identity.TaskId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) void {
        fixture.* = .{
            .ids = .initDeterministic(31337),
            .manual = .init(.fromSeconds(1_000)),
            .ledger = undefined,
            .human = .{ .value = 1 },
            .agent = .{ .value = 2 },
            .task = .{ .value = 3 },
        };
        fixture.ledger = .init(gpa, &fixture.ids, fixture.manual.clock());
    }

    fn deinit(fixture: *Fixture) void {
        fixture.ledger.deinit();
    }
};

test "events are sequenced without gaps" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    for (0..16) |_| {
        _ = try fixture.ledger.append(.{
            .actor = fixture.agent,
            .action = .capability_used,
            .outcome = .succeeded,
        });
    }

    try std.testing.expect(fixture.ledger.verifySequence());
    try std.testing.expectEqual(@as(u64, 1), fixture.ledger.at(0).?.sequence);
    try std.testing.expectEqual(@as(u64, 16), fixture.ledger.at(15).?.sequence);
}

test "a truncated ledger fails sequence verification" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    for (0..4) |_| {
        _ = try fixture.ledger.append(.{
            .actor = fixture.agent,
            .action = .capability_used,
            .outcome = .succeeded,
        });
    }

    // Removing a middle event leaves a gap that verification must notice.
    _ = fixture.ledger.events.orderedRemove(1);
    try std.testing.expect(!fixture.ledger.verifySequence());
}

test "the timestamp comes from the clock, not the caller" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    _ = try fixture.ledger.append(.{
        .actor = fixture.human,
        .action = .authenticated,
        .outcome = .succeeded,
    });
    fixture.manual.advance(.fromSeconds(30));
    _ = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .task_created,
        .outcome = .succeeded,
    });

    try std.testing.expectEqual(@as(i64, 1_000), fixture.ledger.at(0).?.timestamp.seconds());
    try std.testing.expectEqual(@as(i64, 1_030), fixture.ledger.at(1).?.timestamp.seconds());
}

test "a denial records which authority refused and why" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    _ = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .on_behalf_of = fixture.human,
        .action = .action_denied,
        .outcome = .denied,
        .refusal = error.Unauthorized,
        .task = fixture.task,
        .target_kind = "mail",
    });

    const denied = try fixture.ledger.denials(gpa);
    defer gpa.free(denied);

    try std.testing.expectEqual(@as(usize, 1), denied.len);
    try std.testing.expectEqual(DomainError.Unauthorized, denied[0].refusal.?);
    try std.testing.expect(denied[0].on_behalf_of.eql(fixture.human));
    try std.testing.expectEqualStrings("mail", denied[0].target_kind);
}

test "an execution is reconstructable from the task's events" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const other_task: identity.TaskId = .{ .value = 99 };

    _ = try fixture.ledger.append(.{
        .actor = fixture.human,
        .action = .task_created,
        .outcome = .succeeded,
        .task = fixture.task,
    });
    _ = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .capability_used,
        .outcome = .succeeded,
        .task = other_task,
    });
    _ = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .task_completed,
        .outcome = .succeeded,
        .task = fixture.task,
    });

    const reconstructed = try fixture.ledger.eventsForTask(gpa, fixture.task);
    defer gpa.free(reconstructed);

    try std.testing.expectEqual(@as(usize, 2), reconstructed.len);
    try std.testing.expectEqual(Action.task_created, reconstructed[0].action);
    try std.testing.expectEqual(Action.task_completed, reconstructed[1].action);
    // Order of record is preserved, which is what makes replay meaningful.
    try std.testing.expect(reconstructed[0].sequence < reconstructed[1].sequence);
}

test "a causal chain reads from first cause to consequence" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const request = try fixture.ledger.append(.{
        .actor = fixture.human,
        .action = .approval_requested,
        .outcome = .awaiting_approval,
        .task = fixture.task,
    });
    const decision = try fixture.ledger.append(.{
        .actor = fixture.human,
        .action = .approval_decided,
        .outcome = .succeeded,
        .task = fixture.task,
        .parent = request,
    });
    const execution = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .capability_used,
        .outcome = .succeeded,
        .task = fixture.task,
        .parent = decision,
    });

    const chain = try fixture.ledger.causalChain(gpa, execution);
    defer gpa.free(chain);

    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqual(Action.approval_requested, chain[0].action);
    try std.testing.expectEqual(Action.approval_decided, chain[1].action);
    try std.testing.expectEqual(Action.capability_used, chain[2].action);
}

test "whether data left the device is answerable from records alone" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    _ = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .tool_invoked,
        .outcome = .succeeded,
        .data_movement = .stayed_local,
    });
    try std.testing.expect(!fixture.ledger.anyDataLeftDevice());

    _ = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .tool_invoked,
        .outcome = .succeeded,
        .data_movement = .left_device,
        .provenance = .external_service,
    });
    try std.testing.expect(fixture.ledger.anyDataLeftDevice());
}

test "content is referenced by digest and cannot be read back" {
    const message = "the private contents of a message";
    const digest: ContentDigest = .of(message);

    // The digest identifies the content without containing it.
    try std.testing.expect(digest.eql(ContentDigest.of(message)));
    try std.testing.expect(!digest.eql(ContentDigest.of("different content")));
    try std.testing.expect(std.mem.indexOf(u8, &digest.bytes, "private") == null);
}

test "a record carries no content, only its digest" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    _ = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .tool_invoked,
        .outcome = .succeeded,
        .content = .of("a message body that must never be stored"),
        .target_kind = "message",
    });

    const event = fixture.ledger.at(0).?;
    try std.testing.expect(event.content != null);

    // The event type has no field capable of holding the content itself.
    inline for (@typeInfo(Event).@"struct".fields) |field| {
        try std.testing.expect(field.type != []const u8 or
            std.mem.eql(u8, field.name, "target_kind"));
    }
}

test "model output is never recorded as a trustworthy source" {
    try std.testing.expect(!Provenance.model_output.isTrustworthy());
    try std.testing.expect(!Provenance.external_service.isTrustworthy());
    try std.testing.expect(!Provenance.compatibility_runtime.isTrustworthy());
    try std.testing.expect(Provenance.control_plane.isTrustworthy());
    try std.testing.expect(Provenance.local_state.isTrustworthy());
}

test "an actor's whole history is retrievable" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    for (0..3) |_| {
        _ = try fixture.ledger.append(.{
            .actor = fixture.agent,
            .action = .capability_used,
            .outcome = .succeeded,
        });
    }
    _ = try fixture.ledger.append(.{
        .actor = fixture.human,
        .action = .authenticated,
        .outcome = .succeeded,
    });

    const agent_history = try fixture.ledger.eventsForActor(gpa, fixture.agent);
    defer gpa.free(agent_history);
    try std.testing.expectEqual(@as(usize, 3), agent_history.len);

    const human_history = try fixture.ledger.eventsForActor(gpa, fixture.human);
    defer gpa.free(human_history);
    try std.testing.expectEqual(@as(usize, 1), human_history.len);
}

test "a chain walk terminates even if a parent reference forms a cycle" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const first = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .task_created,
        .outcome = .succeeded,
    });
    const second = try fixture.ledger.append(.{
        .actor = fixture.agent,
        .action = .task_completed,
        .outcome = .succeeded,
        .parent = first,
    });
    // Forge a cycle directly in storage; the walk must still terminate.
    fixture.ledger.events.items[0].parent = second;

    const chain = try fixture.ledger.causalChain(gpa, second);
    defer gpa.free(chain);
    try std.testing.expect(chain.len <= fixture.ledger.count() + 1);
}

test "every action that acts under authority is marked as requiring it" {
    try std.testing.expect(Action.capability_used.requiresCapability());
    try std.testing.expect(Action.capability_delegated.requiresCapability());
    try std.testing.expect(!Action.authenticated.requiresCapability());
    try std.testing.expect(!Action.task_created.requiresCapability());
}
