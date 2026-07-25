//! The capability data types: what a grant is, what it covers, and how it is held.
//!
//! These are the values the store issues and checks. They decide nothing on their
//! own — a `Handle` is meaningless without the store that minted it — but they fix
//! the shape of authority: the operations a grant permits, the resource it names,
//! the constraints that bound it, and the context a use is judged against.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const provenance_model = @import("../provenance/provenance.zig");

pub const Operation = enum {
    read,
    list,
    write,
    create,
    delete,
    execute,
    send,
    publish,
    install,
    configure,
    transfer_value,
    grant,

    /// Whether performing this operation changes state outside the system or
    /// is otherwise not silently undoable. These require an approval policy.
    pub fn isConsequential(operation: Operation) bool {
        return switch (operation) {
            .read, .list => false,
            .write,
            .create,
            .delete,
            .execute,
            .send,
            .publish,
            .install,
            .configure,
            .transfer_value,
            .grant,
            => true,
        };
    }
};

pub const OperationSet = std.EnumSet(Operation);

/// What a capability covers.
///
/// A selector names a resource kind and an optional specific resource. A
/// selector without a specific resource covers the kind within the holder's
/// policy domain, which is why `grant` over a whole kind is itself a
/// consequential operation.
pub const ResourceSelector = struct {
    kind: []const u8,
    resource: identity.ResourceId = .none,

    /// Whether `selector` covers `requested`.
    ///
    /// A selector bound to a specific resource covers only that resource. A
    /// selector covering a kind covers any resource of that kind. Coverage is
    /// never widened by the request: an unbound request against a bound
    /// selector is refused.
    pub fn covers(selector: ResourceSelector, requested: ResourceSelector) bool {
        if (!std.mem.eql(u8, selector.kind, requested.kind)) return false;
        if (selector.resource.isNone()) return true;
        return selector.resource.eql(requested.resource);
    }
};

/// What happens to work already in flight when a capability is withdrawn.
///
/// Declared per capability and visible in its type, because the correct
/// behavior differs by operation: interrupting a read is free, interrupting a
/// value transfer half-way is not.
pub const RevocationBehavior = enum {
    /// In-flight work stops at its next cancellation point.
    cancel_immediately,
    /// In-flight work finishes; no further step may begin.
    prevent_next_step,
    /// An atomic operation already committed runs to completion.
    allow_atomic_completion,
    /// The effect must be actively undone by a compensating action.
    requires_compensation,
};

/// Limits attached to a grant.
///
/// Every field narrows authority; none widens it. A constraint left unset means
/// that dimension is unconstrained, so a grant is only as narrow as it was
/// deliberately made.
pub const Constraints = struct {
    /// Not valid before this instant.
    not_before: ?time.Timestamp = null,
    /// Not valid at or after this instant.
    expires_at: ?time.Timestamp = null,
    /// Total number of uses permitted. Null means unlimited.
    invocation_limit: ?u32 = null,
    /// Usable exactly once. Enforced independently of `invocation_limit` so a
    /// one-time grant cannot be widened by raising the limit.
    one_time: bool = false,
    /// Each use requires a fresh human decision.
    requires_human_confirmation: bool = false,
    /// Data may not leave the device to satisfy this operation.
    local_processing_only: bool = false,
    /// Bound to one task. A sibling or descendant task may not use the handle.
    task_binding: identity.TaskId = .none,
    /// Bound to one session.
    session_binding: identity.SessionId = .none,
    /// Bound to one device.
    device_binding: identity.PrincipalId = .none,
    /// Permitted network destinations. Empty means no network access.
    network_destinations: []const []const u8 = &.{},
    /// Permitted recipients for a send or transfer.
    recipients: []const []const u8 = &.{},
    /// Permitted data fields. Empty means every field the resource exposes.
    data_fields: []const []const u8 = &.{},
    /// Maximum value transferable, in the smallest unit of account.
    monetary_limit: ?u64 = null,
    /// Delegations permitted below this grant. Zero forbids delegation.
    delegation_depth: u8 = 0,
    /// How in-flight work is treated on revocation.
    revocation_behavior: RevocationBehavior = .cancel_immediately,
    /// Whether this grant may cross the issuer's policy domain. False by
    /// default: authority stays within one domain unless a grant explicitly
    /// reaches across, and a delegation can never turn this on if its parent did
    /// not already allow it.
    permit_cross_domain: bool = false,
    /// Models this grant may be exercised with. Empty means any model; a
    /// non-empty list confines the grant to exactly those models, so authority
    /// tied to a reviewed model cannot be spent through another.
    model_restrictions: []const []const u8 = &.{},
    /// A ceiling on how often the grant may be used within a rolling window.
    /// Null means only the lifetime `invocation_limit` applies.
    rate_limit: ?RateLimit = null,
};

/// A rolling-window use ceiling: at most `max_uses` uses per `window`.
pub const RateLimit = struct {
    max_uses: u32,
    window: time.Duration,
};

/// The context of one attempted use, checked against the constraints.
pub const UseContext = struct {
    holder: identity.PrincipalId,
    operation: Operation,
    resource: ResourceSelector,
    task: identity.TaskId = .none,
    session: identity.SessionId = .none,
    device: identity.PrincipalId = .none,
    /// Destination for an operation that leaves the device.
    network_destination: ?[]const u8 = null,
    /// Recipient for a send or transfer.
    recipient: ?[]const u8 = null,
    /// Fields the operation will touch.
    data_fields: []const []const u8 = &.{},
    /// Amount for a value transfer, in the smallest unit of account.
    amount: ?u64 = null,
    /// Whether processing stays on the device.
    processing_is_local: bool = true,
    /// Whether a human confirmed this specific use.
    human_confirmed: bool = false,
    /// The model this use runs against, when the grant restricts models.
    model: ?[]const u8 = null,
};

pub const Capability = struct {
    id: identity.CapabilityId,
    issuer: identity.PrincipalId,
    holder: identity.PrincipalId,
    resource: ResourceSelector,
    operations: OperationSet,
    constraints: Constraints,
    issued_at: time.Timestamp,
    /// Uses already spent.
    invocations_used: u32,
    /// When the current rate-limit window opened, and how many uses it has seen.
    /// Only meaningful when `constraints.rate_limit` is set.
    rate_window_started_at: time.Timestamp,
    rate_uses_in_window: u32,
    /// The issuing principal's generation at issue time. A mismatch means the
    /// issuer was revoked after this grant was minted.
    issuer_generation: u64,
    /// Bumped when this grant is revoked, invalidating outstanding handles.
    generation: u64,
    /// Delegation distance from the originating grant.
    depth: u8,
    /// The grant this one was delegated from, if any.
    delegated_from: identity.CapabilityId,
    revoked: bool,
};

/// An opaque reference to a capability.
///
/// Holders receive this. It carries the generation observed at issue, so a
/// handle retained across a revocation is detected rather than silently
/// honored.
pub const Handle = struct {
    id: identity.CapabilityId,
    generation: u64,
};

/// Why a use was refused. Distinguishing these lets the ledger record the real
/// reason rather than a single opaque denial.
/// What a grant is issued with.
pub const Grant = struct {
    issuer: identity.PrincipalId,
    holder: identity.PrincipalId,
    resource: ResourceSelector,
    operations: OperationSet,
    constraints: Constraints = .{},
    /// Where the request for this grant came from. A grant the trusted control
    /// plane mints defaults to a trusted origin; a request derived from model
    /// output or other untrusted input must carry that provenance and is refused
    /// unless it has been validated for `.capability_request`, so an agent cannot
    /// mint authority out of unvalidated model output.
    provenance: provenance_model.Provenance = .from(.control_plane),
};
