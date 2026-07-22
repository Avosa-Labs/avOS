//! Capabilities: explicit, unforgeable grants of authority.
//!
//! Nothing in this system is permitted because of who is asking or which
//! process is running. Authority is a value that was issued, is held, names
//! what it covers, and can be checked. A component with no capability for an
//! operation cannot perform it, however privileged its surroundings.
//!
//! Holders receive opaque handles, never a pointer to a record. A handle is
//! meaningless without the issuing store, so possessing one confers nothing on
//! its own and forging one is not a matter of constructing a struct.
//!
//! Every constraint is checked at the moment of use, not at issue. Authority
//! that was valid when granted may be expired, revoked, exhausted, or out of
//! scope by the time it is exercised, and that gap is where confused-deputy and
//! replay attacks live.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const outcome = @import("../base/outcome.zig");
const principal_model = @import("../principal/principal.zig");

const DomainError = outcome.DomainError;

/// What may be done to a resource.
///
/// A set rather than a single value because one grant commonly covers a
/// coherent group, and because checking a set membership is the operation on
/// the hot authorization path.
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
pub const Refusal = enum {
    unknown_handle,
    stale_handle,
    revoked,
    issuer_revoked,
    not_yet_valid,
    expired,
    wrong_holder,
    holder_not_authorized,
    operation_not_granted,
    resource_not_covered,
    task_binding_violated,
    session_binding_violated,
    device_binding_violated,
    invocations_exhausted,
    confirmation_required,
    remote_processing_forbidden,
    destination_not_permitted,
    recipient_not_permitted,
    field_not_permitted,
    monetary_limit_exceeded,
    delegation_forbidden,
    delegation_would_widen,

    /// The error a refusal surfaces to the caller. Several distinct refusals
    /// map onto one error deliberately: the caller learns it may not proceed,
    /// while the ledger retains which check failed.
    pub fn toError(refusal: Refusal) DomainError {
        return switch (refusal) {
            .unknown_handle,
            .wrong_holder,
            .holder_not_authorized,
            .operation_not_granted,
            .resource_not_covered,
            => error.Unauthorized,
            .stale_handle => error.IntegrityFailure,
            .revoked, .issuer_revoked => error.CapabilityRevoked,
            .expired => error.CapabilityExpired,
            .not_yet_valid,
            .task_binding_violated,
            .session_binding_violated,
            .device_binding_violated,
            .confirmation_required,
            .remote_processing_forbidden,
            .destination_not_permitted,
            .recipient_not_permitted,
            .field_not_permitted,
            .monetary_limit_exceeded,
            .delegation_forbidden,
            .delegation_would_widen,
            => error.ConstraintViolation,
            .invocations_exhausted => error.BudgetExhausted,
        };
    }
};

/// What a grant is issued with.
pub const Grant = struct {
    issuer: identity.PrincipalId,
    holder: identity.PrincipalId,
    resource: ResourceSelector,
    operations: OperationSet,
    constraints: Constraints = .{},
};

/// The authoritative capability set for this host.
///
/// Ownership: the store owns its records and the strings it copies out of every
/// selector and constraint list. `deinit` releases all of it. Callers hold
/// handles, never pointers into the store.
///
/// Lookup and validation are expected O(1) in the number of outstanding
/// capabilities: they sit on the path of every privileged operation.
pub const Store = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    clock: time.Clock,
    principals: *const principal_model.Registry,
    entries: std.AutoHashMapUnmanaged(u128, Capability) = .empty,
    /// Copied strings owned by this store, released together at `deinit`.
    owned_text: std.ArrayList([]const u8) = .empty,
    /// Copied string lists owned by this store. Tracked separately from
    /// `owned_text` so each is released with the type and alignment it was
    /// allocated with.
    owned_lists: std.ArrayList([]const []const u8) = .empty,

    /// The most recent refusal, for the caller to record in the ledger. Set
    /// only when a check fails.
    last_refusal: ?Refusal = null,

    pub fn init(
        gpa: std.mem.Allocator,
        ids: *identity.Source,
        clock: time.Clock,
        principals: *const principal_model.Registry,
    ) Store {
        return .{ .gpa = gpa, .ids = ids, .clock = clock, .principals = principals };
    }

    pub fn deinit(store: *Store) void {
        for (store.owned_lists.items) |list| store.gpa.free(list);
        store.owned_lists.deinit(store.gpa);
        for (store.owned_text.items) |text| store.gpa.free(text);
        store.owned_text.deinit(store.gpa);
        store.entries.deinit(store.gpa);
        store.* = undefined;
    }

    fn ownText(store: *Store, text: []const u8) ![]const u8 {
        const copy = try store.gpa.dupe(u8, text);
        errdefer store.gpa.free(copy);
        try store.owned_text.append(store.gpa, copy);
        return copy;
    }

    fn ownTextList(store: *Store, list: []const []const u8) ![]const []const u8 {
        if (list.len == 0) return &.{};
        const copies = try store.gpa.alloc([]const u8, list.len);
        errdefer store.gpa.free(copies);
        for (list, copies) |source, *destination| destination.* = try store.ownText(source);
        try store.owned_lists.append(store.gpa, copies);
        return copies;
    }

    fn ownConstraints(store: *Store, constraints: Constraints) !Constraints {
        var owned = constraints;
        owned.network_destinations = try store.ownTextList(constraints.network_destinations);
        owned.recipients = try store.ownTextList(constraints.recipients);
        owned.data_fields = try store.ownTextList(constraints.data_fields);
        return owned;
    }

    /// Issues a grant and returns a handle for the holder.
    ///
    /// The issuer must itself be able to act. Issuing from a revoked or expired
    /// principal would create authority that outlives the authority to create
    /// it.
    pub fn issue(store: *Store, grant: Grant) !Handle {
        const issuer = try store.principals.authorize(grant.issuer);
        _ = try store.principals.authorize(grant.holder);

        const id = store.ids.next(identity.CapabilityId);
        const owned_resource: ResourceSelector = .{
            .kind = try store.ownText(grant.resource.kind),
            .resource = grant.resource.resource,
        };

        try store.entries.put(store.gpa, id.value, .{
            .id = id,
            .issuer = grant.issuer,
            .holder = grant.holder,
            .resource = owned_resource,
            .operations = grant.operations,
            .constraints = try store.ownConstraints(grant.constraints),
            .issued_at = store.clock.wall(),
            .invocations_used = 0,
            .issuer_generation = issuer.generation,
            .generation = 0,
            .depth = 0,
            .delegated_from = .none,
            .revoked = false,
        });

        return .{ .id = id, .generation = 0 };
    }

    /// Delegates a subset of an existing grant to another holder.
    ///
    /// A delegation may only narrow. It cannot add an operation, widen the
    /// resource, extend the expiry, raise a monetary limit, or increase
    /// delegation depth beyond what the parent allows. This is the check that
    /// stops an agent manufacturing authority it was never given.
    pub fn delegate(
        store: *Store,
        parent_handle: Handle,
        new_holder: identity.PrincipalId,
        operations: OperationSet,
        resource: ResourceSelector,
        constraints: Constraints,
    ) !Handle {
        const parent = try store.resolve(parent_handle);

        if (parent.constraints.delegation_depth == 0) return store.refuse(.delegation_forbidden);
        _ = try store.principals.authorize(new_holder);

        // A delegation must not exceed the parent in any dimension.
        if (!operations.subsetOf(parent.operations)) return store.refuse(.delegation_would_widen);
        if (!parent.resource.covers(resource)) return store.refuse(.delegation_would_widen);
        if (widensExpiry(parent.constraints, constraints)) return store.refuse(.delegation_would_widen);
        if (widensMonetaryLimit(parent.constraints, constraints)) return store.refuse(.delegation_would_widen);
        if (constraints.delegation_depth >= parent.constraints.delegation_depth) {
            return store.refuse(.delegation_would_widen);
        }
        if (parent.constraints.local_processing_only and !constraints.local_processing_only) {
            return store.refuse(.delegation_would_widen);
        }
        if (parent.constraints.requires_human_confirmation and
            !constraints.requires_human_confirmation)
        {
            return store.refuse(.delegation_would_widen);
        }

        const id = store.ids.next(identity.CapabilityId);
        const owned_resource: ResourceSelector = .{
            .kind = try store.ownText(resource.kind),
            .resource = resource.resource,
        };

        try store.entries.put(store.gpa, id.value, .{
            .id = id,
            .issuer = parent.holder,
            .holder = new_holder,
            .resource = owned_resource,
            .operations = operations,
            .constraints = try store.ownConstraints(constraints),
            .issued_at = store.clock.wall(),
            .invocations_used = 0,
            .issuer_generation = (try store.principals.authorize(parent.holder)).generation,
            .generation = 0,
            .depth = parent.depth + 1,
            .delegated_from = parent.id,
            .revoked = false,
        });

        return .{ .id = id, .generation = 0 };
    }

    fn resolve(store: *Store, handle: Handle) DomainError!Capability {
        const record = store.entries.get(handle.id.value) orelse
            return store.refuse(.unknown_handle);
        // The generation observed at issue must still hold; otherwise the
        // handle predates a revocation.
        if (record.generation != handle.generation) return store.refuse(.stale_handle);
        return record;
    }

    fn refuse(store: *Store, refusal: Refusal) DomainError {
        store.last_refusal = refusal;
        return refusal.toError();
    }

    /// Checks a use without consuming an invocation.
    ///
    /// Every dimension is revalidated here rather than trusted from issue time,
    /// because the gap between lookup and use is exactly where a revoked or
    /// expired grant would otherwise be honored.
    pub fn check(store: *Store, handle: Handle, context: UseContext) DomainError!Capability {
        const record = try store.resolve(handle);
        const now = store.clock.wall();

        if (record.revoked) return store.refuse(.revoked);

        // The issuer's authority must still stand behind the grant.
        const issuer = store.principals.lookup(record.issuer) orelse
            return store.refuse(.issuer_revoked);
        if (issuer.generation != record.issuer_generation) return store.refuse(.issuer_revoked);
        if (!issuer.isActive(now)) return store.refuse(.issuer_revoked);

        if (!record.holder.eql(context.holder)) return store.refuse(.wrong_holder);
        _ = store.principals.authorize(record.holder) catch
            return store.refuse(.holder_not_authorized);

        if (record.constraints.not_before) |not_before| {
            if (now.order(not_before) == .lt) return store.refuse(.not_yet_valid);
        }
        if (record.constraints.expires_at) |expires_at| {
            if (!expires_at.isAfter(now)) return store.refuse(.expired);
        }

        if (!record.operations.contains(context.operation)) {
            return store.refuse(.operation_not_granted);
        }
        if (!record.resource.covers(context.resource)) return store.refuse(.resource_not_covered);

        if (!record.constraints.task_binding.isNone() and
            !record.constraints.task_binding.eql(context.task))
        {
            return store.refuse(.task_binding_violated);
        }
        if (!record.constraints.session_binding.isNone() and
            !record.constraints.session_binding.eql(context.session))
        {
            return store.refuse(.session_binding_violated);
        }
        if (!record.constraints.device_binding.isNone() and
            !record.constraints.device_binding.eql(context.device))
        {
            return store.refuse(.device_binding_violated);
        }

        const limit = permittedInvocations(record.constraints);
        if (limit) |maximum| {
            if (record.invocations_used >= maximum) return store.refuse(.invocations_exhausted);
        }

        if (record.constraints.requires_human_confirmation and !context.human_confirmed) {
            return store.refuse(.confirmation_required);
        }
        if (record.constraints.local_processing_only and !context.processing_is_local) {
            return store.refuse(.remote_processing_forbidden);
        }

        if (context.network_destination) |destination| {
            if (!containsText(record.constraints.network_destinations, destination)) {
                return store.refuse(.destination_not_permitted);
            }
        }
        if (context.recipient) |recipient| {
            if (!containsText(record.constraints.recipients, recipient)) {
                return store.refuse(.recipient_not_permitted);
            }
        }
        if (record.constraints.data_fields.len != 0) {
            for (context.data_fields) |field| {
                if (!containsText(record.constraints.data_fields, field)) {
                    return store.refuse(.field_not_permitted);
                }
            }
        }
        if (context.amount) |amount| {
            const maximum = record.constraints.monetary_limit orelse
                return store.refuse(.monetary_limit_exceeded);
            if (amount > maximum) return store.refuse(.monetary_limit_exceeded);
        }

        return record;
    }

    /// Checks a use and consumes an invocation.
    ///
    /// Consumption happens only after every check passes, so a refused attempt
    /// never spends a one-time grant. This is what makes an approved action
    /// execute exactly once: the second attempt finds the invocation spent.
    pub fn use(store: *Store, handle: Handle, context: UseContext) DomainError!Capability {
        const record = try store.check(handle, context);
        const entry = store.entries.getPtr(handle.id.value) orelse
            return store.refuse(.unknown_handle);
        entry.invocations_used += 1;
        store.last_refusal = null;
        return record;
    }

    /// Withdraws a grant. Outstanding handles become stale immediately.
    ///
    /// Delegations below this grant are withdrawn with it: authority that was
    /// derived from a withdrawn grant cannot outlive it.
    pub fn revoke(store: *Store, id: identity.CapabilityId) DomainError!void {
        const entry = store.entries.getPtr(id.value) orelse return error.Unauthorized;
        if (entry.revoked) return; // Idempotent.
        entry.revoked = true;
        entry.generation += 1;

        var iterator = store.entries.valueIterator();
        while (iterator.next()) |candidate| {
            if (candidate.delegated_from.eql(id) and !candidate.revoked) {
                candidate.revoked = true;
                candidate.generation += 1;
            }
        }
    }

    pub fn lookup(store: Store, id: identity.CapabilityId) ?Capability {
        return store.entries.get(id.value);
    }

    pub fn count(store: Store) usize {
        return store.entries.count();
    }
};

/// A one-time grant is capped at a single use regardless of any stated limit,
/// so the two constraints cannot be played against each other.
fn permittedInvocations(constraints: Constraints) ?u32 {
    if (constraints.one_time) {
        const stated = constraints.invocation_limit orelse 1;
        return @min(stated, 1);
    }
    return constraints.invocation_limit;
}

fn widensExpiry(parent: Constraints, child: Constraints) bool {
    const parent_expiry = parent.expires_at orelse return false;
    const child_expiry = child.expires_at orelse return true;
    return child_expiry.isAfter(parent_expiry);
}

fn widensMonetaryLimit(parent: Constraints, child: Constraints) bool {
    const parent_limit = parent.monetary_limit orelse return false;
    const child_limit = child.monetary_limit orelse return true;
    return child_limit > parent_limit;
}

fn containsText(list: []const []const u8, value: []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

// A fixture assembling the registry, store, and principals every test needs.
const Fixture = struct {
    gpa: std.mem.Allocator,
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal_model.Registry,
    store: Store,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,
    other_agent: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        fixture.* = .{
            .gpa = gpa,
            .ids = .initDeterministic(20260722),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .human = .none,
            .agent = .none,
            .other_agent = .none,
        };
        fixture.registry = .init(gpa, &fixture.ids, fixture.manual.clock());
        fixture.store = .init(gpa, &fixture.ids, fixture.manual.clock(), &fixture.registry);

        fixture.human = try fixture.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        });
        fixture.agent = try fixture.registry.enroll(.{
            .kind = .agent,
            .display_name = "calendar",
            .policy_domain = "local",
            .expires_at = .fromSeconds(100_000),
            .issuer = fixture.human,
        });
        fixture.other_agent = try fixture.registry.enroll(.{
            .kind = .agent,
            .display_name = "travel",
            .policy_domain = "local",
            .expires_at = .fromSeconds(100_000),
            .issuer = fixture.human,
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    fn readOnly(fixture: *Fixture) OperationSet {
        _ = fixture;
        var set: OperationSet = .initEmpty();
        set.insert(.read);
        return set;
    }
};

test "a grant permits exactly what it names" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
    });

    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    });

    // An operation outside the grant is refused even for the right holder.
    try std.testing.expectError(error.Unauthorized, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .write,
        .resource = .{ .kind = "calendar" },
    }));
    try std.testing.expectEqual(Refusal.operation_not_granted, fixture.store.last_refusal.?);

    // A different resource kind is refused.
    try std.testing.expectError(error.Unauthorized, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "mail" },
    }));
    try std.testing.expectEqual(Refusal.resource_not_covered, fixture.store.last_refusal.?);
}

test "a handle is useless to a principal that does not hold it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
    });

    // Stealing the handle value gains nothing without being the holder.
    try std.testing.expectError(error.Unauthorized, fixture.store.check(handle, .{
        .holder = fixture.other_agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
    try std.testing.expectEqual(Refusal.wrong_holder, fixture.store.last_refusal.?);
}

test "a revoked grant is refused and its handle is stale" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
    });
    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    });

    try fixture.store.revoke(handle.id);

    // The retained handle carries the pre-revocation generation.
    try std.testing.expectError(error.IntegrityFailure, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
    try std.testing.expectEqual(Refusal.stale_handle, fixture.store.last_refusal.?);
}

test "revoking a principal invalidates the grants it issued" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
    });

    try fixture.registry.revoke(fixture.human);

    // Authority cannot outlive the authority that granted it.
    try std.testing.expectError(error.CapabilityRevoked, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
    try std.testing.expectEqual(Refusal.issuer_revoked, fixture.store.last_refusal.?);
}

test "expiry is evaluated at use, not at issue" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .expires_at = .fromSeconds(1_060) },
    });

    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    });

    fixture.manual.advance(.fromSeconds(120));

    try std.testing.expectError(error.CapabilityExpired, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
}

test "a capability expiring between check and use is refused at use" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .expires_at = .fromSeconds(1_030) },
    });

    const context: UseContext = .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    };

    _ = try fixture.store.check(handle, context);
    fixture.manual.advance(.fromSeconds(60));
    try std.testing.expectError(error.CapabilityExpired, fixture.store.use(handle, context));
}

test "a one-time grant executes exactly once" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var send: OperationSet = .initEmpty();
    send.insert(.send);

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "message" },
        .operations = send,
        .constraints = .{ .one_time = true, .recipients = &.{"the venue"} },
    });

    const context: UseContext = .{
        .holder = fixture.agent,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .recipient = "the venue",
    };

    _ = try fixture.store.use(handle, context);
    try std.testing.expectError(error.BudgetExhausted, fixture.store.use(handle, context));
    try std.testing.expectEqual(Refusal.invocations_exhausted, fixture.store.last_refusal.?);
}

test "a stated limit cannot widen a one-time grant" {
    const constraints: Constraints = .{ .one_time = true, .invocation_limit = 100 };
    try std.testing.expectEqual(@as(?u32, 1), permittedInvocations(constraints));
}

test "a refused attempt does not spend an invocation" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var send: OperationSet = .initEmpty();
    send.insert(.send);

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "message" },
        .operations = send,
        .constraints = .{ .one_time = true, .recipients = &.{"the venue"} },
    });

    // Wrong recipient: refused, and the single use must remain available.
    try std.testing.expectError(error.ConstraintViolation, fixture.store.use(handle, .{
        .holder = fixture.agent,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .recipient = "someone else",
    }));

    _ = try fixture.store.use(handle, .{
        .holder = fixture.agent,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .recipient = "the venue",
    });
}

test "task binding rejects replay from a sibling task" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const bound_task: identity.TaskId = .{ .value = 77 };
    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .task_binding = bound_task },
    });

    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .task = bound_task,
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .task = .{ .value = 78 },
    }));
    try std.testing.expectEqual(Refusal.task_binding_violated, fixture.store.last_refusal.?);
}

test "a specific resource grant does not cover the whole kind" {
    const specific: ResourceSelector = .{ .kind = "document", .resource = .{ .value = 5 } };
    try std.testing.expect(specific.covers(.{ .kind = "document", .resource = .{ .value = 5 } }));
    try std.testing.expect(!specific.covers(.{ .kind = "document", .resource = .{ .value = 6 } }));
    try std.testing.expect(!specific.covers(.{ .kind = "document" }));

    const whole_kind: ResourceSelector = .{ .kind = "document" };
    try std.testing.expect(whole_kind.covers(.{ .kind = "document", .resource = .{ .value = 5 } }));
    try std.testing.expect(!whole_kind.covers(.{ .kind = "mail" }));
}

test "local-only processing refuses a remote execution" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "document" },
        .operations = fixture.readOnly(),
        .constraints = .{ .local_processing_only = true },
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "document" },
        .processing_is_local = false,
    }));
    try std.testing.expectEqual(Refusal.remote_processing_forbidden, fixture.store.last_refusal.?);
}

test "a monetary limit bounds a transfer and an unstated amount is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var transfer: OperationSet = .initEmpty();
    transfer.insert(.transfer_value);

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "payment" },
        .operations = transfer,
        .constraints = .{ .monetary_limit = 5_000, .recipients = &.{"the venue"} },
    });

    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .transfer_value,
        .resource = .{ .kind = "payment" },
        .recipient = "the venue",
        .amount = 5_000,
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .transfer_value,
        .resource = .{ .kind = "payment" },
        .recipient = "the venue",
        .amount = 5_001,
    }));
}

test "network access is denied unless a destination was granted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "route" },
        .operations = fixture.readOnly(),
        .constraints = .{ .network_destinations = &.{"routing.invalid"} },
    });

    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "route" },
        .network_destination = "routing.invalid",
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "route" },
        .network_destination = "elsewhere.invalid",
    }));
}

test "field scope restricts which data an operation may touch" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .data_fields = &.{ "start", "end" } },
    });

    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .data_fields = &.{"start"},
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .data_fields = &.{ "start", "attendee_notes" },
    }));
}

test "delegation is forbidden unless depth was granted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        handle,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{},
    ));
    try std.testing.expectEqual(Refusal.delegation_forbidden, fixture.store.last_refusal.?);
}

test "a delegation may narrow but never widen" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var read_write: OperationSet = .initEmpty();
    read_write.insert(.read);
    read_write.insert(.write);

    const parent = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = read_write,
        .constraints = .{
            .delegation_depth = 1,
            .expires_at = .fromSeconds(2_000),
            .monetary_limit = 1_000,
        },
    });

    // Narrowing to read-only within the parent's window is permitted.
    const narrowed = try fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{ .expires_at = .fromSeconds(1_500), .monetary_limit = 500 },
    );
    try std.testing.expectEqual(@as(u8, 1), fixture.store.lookup(narrowed.id).?.depth);

    // Adding an operation the parent lacks.
    var with_delete: OperationSet = .initEmpty();
    with_delete.insert(.delete);
    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        parent,
        fixture.other_agent,
        with_delete,
        .{ .kind = "calendar" },
        .{ .expires_at = .fromSeconds(1_500) },
    ));

    // Extending beyond the parent's expiry.
    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{ .expires_at = .fromSeconds(9_000) },
    ));

    // Dropping the expiry entirely.
    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{},
    ));

    // Raising the monetary ceiling.
    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{ .expires_at = .fromSeconds(1_500), .monetary_limit = 5_000 },
    ));
}

test "delegation depth strictly decreases and bottoms out" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const root = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .delegation_depth = 2 },
    });

    const first = try fixture.store.delegate(
        root,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{ .delegation_depth = 1 },
    );

    // The chain must terminate: a depth-1 grant can delegate only depth 0,
    // which forbids delegating further.
    const second = try fixture.store.delegate(
        first,
        fixture.agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{ .delegation_depth = 0 },
    );
    try std.testing.expectEqual(@as(u8, 2), fixture.store.lookup(second.id).?.depth);

    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        second,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{},
    ));
}

test "a delegation cannot escape a local-only or confirmation constraint" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const parent = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "document" },
        .operations = fixture.readOnly(),
        .constraints = .{
            .delegation_depth = 1,
            .local_processing_only = true,
            .requires_human_confirmation = true,
        },
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "document" },
        .{ .requires_human_confirmation = true },
    ));

    try std.testing.expectError(error.ConstraintViolation, fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "document" },
        .{ .local_processing_only = true },
    ));

    _ = try fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "document" },
        .{ .local_processing_only = true, .requires_human_confirmation = true },
    );
}

test "revoking a grant revokes what was delegated from it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const parent = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .delegation_depth = 1 },
    });
    const child = try fixture.store.delegate(
        parent,
        fixture.other_agent,
        fixture.readOnly(),
        .{ .kind = "calendar" },
        .{},
    );

    _ = try fixture.store.check(child, .{
        .holder = fixture.other_agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    });

    try fixture.store.revoke(parent.id);

    try std.testing.expect(fixture.store.lookup(child.id).?.revoked);
    try std.testing.expectError(error.IntegrityFailure, fixture.store.check(child, .{
        .holder = fixture.other_agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
}

test "human confirmation is required for each use when constrained" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var send: OperationSet = .initEmpty();
    send.insert(.send);

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "message" },
        .operations = send,
        .constraints = .{ .requires_human_confirmation = true, .recipients = &.{"the venue"} },
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .recipient = "the venue",
    }));

    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .recipient = "the venue",
        .human_confirmed = true,
    });
}

test "a not-yet-valid grant is refused until its window opens" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .not_before = .fromSeconds(2_000) },
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
    try std.testing.expectEqual(Refusal.not_yet_valid, fixture.store.last_refusal.?);

    fixture.manual.advance(.fromSeconds(1_500));
    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    });
}

test "an unknown handle is refused without revealing whether it ever existed" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const forged: Handle = .{ .id = .{ .value = 0xfeed }, .generation = 0 };
    try std.testing.expectError(error.Unauthorized, fixture.store.check(forged, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    }));
    try std.testing.expectEqual(Refusal.unknown_handle, fixture.store.last_refusal.?);
}

test "every refusal maps to an actionable error" {
    for (std.enums.values(Refusal)) |refusal| {
        const mapped = refusal.toError();
        try std.testing.expect(outcome.describe(mapped).len > 0);
        // A refusal stops an operation, so it must never resolve to success
        // and never to an ambiguous external result that would invite a retry.
        const resulting = outcome.outcomeOf(mapped);
        try std.testing.expect(resulting != .succeeded);
        try std.testing.expect(resulting != .outcome_unknown);
    }
}

test "read and list are the only non-consequential operations" {
    for (std.enums.values(Operation)) |operation| {
        const expected = operation == .read or operation == .list;
        try std.testing.expectEqual(expected, !operation.isConsequential());
    }
}
