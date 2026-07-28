//! The frame every default app is built on, and the two invariants that keep it
//! honest: one domain behind two doors, and a feed that reads the ledger rather than
//! the agent's mouth.
//!
//! An app on this platform is one shared domain — the real logic and state — reached
//! through two doors that call exactly the same code. The human door is the app's
//! surface; the agent door is its registered capabilities. Both funnel every operation
//! through `invoke` here, and `invoke` calls the one domain, so an agent sending a
//! message runs the identical function the person's finger runs. The instant an agent
//! path and a human path had separate logic, the live-watch demo would be theatre — the
//! agent doing something the person never exercises. One domain, two doors, forecloses
//! that.
//!
//! The second invariant is where the watching becomes truthful. Every step of an
//! invocation writes the audit ledger: a capability that does not authorize the call is
//! a denial recorded before anything runs (fail-closed, and visible), a consequential
//! act by an agent is an approval request recorded and held, and a completed operation
//! is recorded with its outcome. The activity feed is then *derived from that ledger* —
//! it reads the recorded events, never a string an agent supplied about itself. So
//! watching an agent work is watching the same ground truth that gated the work. If the
//! feed read the agent's self-report instead, it would be simulation with extra steps.
//!
//! This module executes no app logic. It gates an operation against the app's
//! capabilities, records every step to the ledger, dispatches the permitted ones to the
//! app's own domain, and derives the feed from the record.

const std = @import("std");
const core = @import("core");
const agents = @import("agents");

const audit = core.audit;
const identity = core.identity;
const registry = agents.tool_registry;

pub const Ledger = audit.Ledger;
pub const Tool = registry.Tool;
pub const Registry = registry.Registry;
pub const Effect = registry.Effect;

/// The settings policy registry, reached through the framework so an app is a viewer over policy
/// without importing the system directly.
pub const settings = core.policy.settings;

/// The slice of the platform an app is allowed to use — calendar dates, time zones, and instants —
/// re-exported so an app reaches them through the frame rather than importing the core plane
/// directly. The boundary check forbids an app file its own `@import("core")`; this is how an app
/// that needs real date-and-time arithmetic gets it without crossing that boundary.
pub const platform = struct {
    pub const time = core.time;
    pub const civil = core.civil;
    pub const zone = core.zone;
};

/// How the data an app handles is classified for the model router: whether it may ever leave the
/// device. An app declares this so the router can honour "this data class never leaves the device"
/// — the same classification a connector carries, stated at the app so it is discoverable per app.
pub const DataPrivacy = enum {
    /// The app's data is the person's private world (messages, contacts, files, calendar frames,
    /// call history): it never leaves the device without a separate, explicit per-use grant.
    on_device,
    /// The app's data is inherently public or external (a weather forecast, a web page, a store
    /// catalogue): it may leave the device under the ordinary authority its operations carry.
    shareable,

    /// Whether this class may be routed to an off-device model without a per-use grant.
    pub fn mayLeaveDevice(privacy: DataPrivacy) bool {
        return privacy == .shareable;
    }
};

/// Whether an app's domain needs an external provider to do real work. This is the static
/// half of the connector story: a local-real app is genuinely on-device and is never
/// simulated, while a needs-provider app reaches an external service and so runs
/// connector-pending — a labeled simulator answering — until a real provider is linked, at
/// which point the same capabilities operate on live data with no code change.
pub const ConnectorNeed = enum {
    /// The domain is genuinely local; no external provider, no simulation, ever.
    local_real,
    /// The domain reaches an external service; connector-pending until a real provider is
    /// linked in Settings, then live.
    needs_provider,

    /// Whether a real provider must be linked before this app can leave connector-pending.
    pub fn awaitsProvider(need: ConnectorNeed) bool {
        return need == .needs_provider;
    }
};

/// Who is acting through the app: the person, or a specific agent.
pub const Actor = struct {
    kind: enum { human, agent },
    principal: identity.PrincipalId,

    pub fn isAgent(actor: Actor) bool {
        return actor.kind == .agent;
    }
};

/// The result the app's domain returns from actually doing the work. The domain is the
/// one place logic and state live; both doors reach it only through `invoke`.
pub const DomainResult = union(enum) {
    /// The operation ran; its effect is durable. The bytes are its result payload.
    ok: []const u8,
    /// The operation ran and failed.
    failed,
};

/// The input to an operation: the operation name and its argument bytes, the same for
/// both doors. The argument shape is the app's own — a setting key, a file path, a
/// message body — which the domain interprets; the framework passes it through
/// unread, so an agent's input and a person's input reach the domain identically.
pub const Input = struct {
    operation: []const u8,
    args: []const u8 = "",
};

/// The app's domain: the shared logic and state behind both doors. An app implements
/// one of these; the framework never inspects what it does, only that both doors reach
/// it through the same call.
pub const Domain = struct {
    context: *anyopaque,
    /// Executes an operation with its arguments. `key` is the idempotency key: a domain
    /// records applied keys so a re-driven or re-approved operation runs its effect
    /// exactly once.
    execute_fn: *const fn (context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult,

    fn execute(domain: Domain, input: Input, actor: Actor, key: u128) DomainResult {
        return domain.execute_fn(domain.context, input, actor, key);
    }
};

/// How an invocation resolved.
pub const Outcome = union(enum) {
    /// The operation ran through the domain; the bytes are its result.
    executed: []const u8,
    /// A consequential operation an agent requested, held for a person to approve.
    held,
    /// The operation was denied before anything ran, and the denial is in the ledger.
    denied: registry.Refusal,
    /// The operation ran and failed.
    failed,

    pub fn ran(outcome: Outcome) bool {
        return outcome == .executed;
    }
};

/// An app: its domain, the capabilities it registers for agents to discover, and the
/// ledger every operation is recorded to.
///
/// Ownership: the app borrows the ledger — the control plane owns it and other
/// subsystems record to the same one, which is why the feed can show an agent's whole
/// footprint, not just this app's. The tool set is static data the app defines.
pub const App = struct {
    name: []const u8,
    domain: Domain,
    tools: Registry,
    ledger: *Ledger,

    /// Invokes an operation, gated and recorded, and dispatched to the one domain.
    ///
    /// The order is the real checklist, and every branch writes the ledger. The
    /// operation must be a registered capability whose required authority the caller
    /// presents — the tool registry decides this, so a hallucinated operation or a
    /// capability mismatch is denied and recorded, not guessed at. A consequential
    /// operation an agent requests is held for a person and recorded as an approval
    /// request rather than run. Anything permitted runs through the domain — the same
    /// domain the human door calls — and its outcome is recorded. `holds_capability`
    /// is the verdict of the capability service's full check, resolved by the caller;
    /// the framework enforces the gate and the record, the service decides the grant.
    pub fn invoke(
        app: *App,
        actor: Actor,
        input: Input,
        presented_capability: []const u8,
        holds_capability: bool,
        key: u128,
    ) !Outcome {
        const operation = input.operation;
        // The registry decides discovery and the capability-name match, and returns
        // whether a permitted call is consequential. A hallucinated operation or a
        // mismatched capability is denied here.
        const decision = app.tools.admit(operation, presented_capability);
        switch (decision) {
            .deny => |refusal| {
                _ = try app.record(actor, operation, .action_denied, .denied, key);
                return .{ .denied = refusal };
            },
            .require_approval => {
                // The capability service's full-checklist verdict, resolved by the
                // caller. A negative verdict is a denial recorded before anything runs.
                if (!holds_capability) {
                    _ = try app.record(actor, operation, .action_denied, .denied, key);
                    return .{ .denied = .capability_mismatch };
                }
                // A consequential operation an agent requests is held for the person; a
                // person performs their own consequential act directly.
                if (actor.isAgent()) {
                    _ = try app.record(actor, operation, .approval_requested, .awaiting_approval, key);
                    return .held;
                }
                return app.executeAndRecord(actor, input, key);
            },
            .invoke => {
                if (!holds_capability) {
                    _ = try app.record(actor, operation, .action_denied, .denied, key);
                    return .{ .denied = .capability_mismatch };
                }
                return app.executeAndRecord(actor, input, key);
            },
        }
    }

    /// Completes a previously held operation on a person's decision. The domain keys
    /// the effect by `key`, so approving is exactly-once even if the person taps twice
    /// or the process restarted between the hold and the approval.
    pub fn approve(app: *App, approver: Actor, input: Input, key: u128) !Outcome {
        _ = try app.record(approver, input.operation, .approval_decided, .succeeded, key);
        return app.executeAndRecord(approver, input, key);
    }

    fn executeAndRecord(app: *App, actor: Actor, input: Input, key: u128) !Outcome {
        switch (app.domain.execute(input, actor, key)) {
            .ok => |result| {
                _ = try app.record(actor, input.operation, .tool_invoked, .succeeded, key);
                return .{ .executed = result };
            },
            .failed => {
                _ = try app.record(actor, input.operation, .tool_invoked, .failed, key);
                return .failed;
            },
        }
    }

    fn record(app: *App, actor: Actor, operation: []const u8, action: audit.Action, outcome: core.outcome.Outcome, key: u128) !identity.AuditEventId {
        _ = key; // the idempotency key gates the effect in the domain, not the record
        return app.ledger.append(.{
            .actor = actor.principal,
            .action = action,
            .outcome = outcome,
            .target_kind = operation,
            .provenance = if (actor.isAgent()) .model_output else .human_input,
        });
    }
};

/// One item in the live activity feed, derived from a ledger event. It carries only
/// what the record carries — who acted, what they did, how it resolved — because the
/// feed is a view of the ledger, not a channel an agent writes to.
pub const FeedItem = struct {
    actor: identity.PrincipalId,
    operation: []const u8,
    action: audit.Action,
    outcome: core.outcome.Outcome,
    sequence: u64,

    fn of(event: audit.Event) FeedItem {
        return .{
            .actor = event.actor,
            .operation = event.target_kind,
            .action = event.action,
            .outcome = event.outcome,
            .sequence = event.sequence,
        };
    }
};

/// Derives an actor's activity feed from the ledger — the person's live view of what an
/// agent (or they themselves) did, read from the recorded events and nothing else.
/// Caller owns the returned slice.
pub fn feedForActor(ledger: *Ledger, gpa: std.mem.Allocator, actor: identity.PrincipalId) ![]FeedItem {
    const events = try ledger.eventsForActor(gpa, actor);
    defer gpa.free(events);
    const items = try gpa.alloc(FeedItem, events.len);
    for (events, items) |event, *item| item.* = FeedItem.of(event);
    return items;
}

/// The denials in the feed — the operations that were refused, which a person watching
/// must see as clearly as the ones that ran. Derived from the ledger's denials.
pub fn deniedFeed(ledger: *Ledger, gpa: std.mem.Allocator) ![]FeedItem {
    const events = try ledger.denials(gpa);
    defer gpa.free(events);
    const items = try gpa.alloc(FeedItem, events.len);
    for (events, items) |event, *item| item.* = FeedItem.of(event);
    return items;
}
