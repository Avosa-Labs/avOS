//! The authoritative capability store: issue, delegate, check, use, and revoke.
//!
//! Every constraint is revalidated at the moment of use rather than trusted from
//! issue time, because the gap between lookup and use is where a revoked, expired,
//! or exhausted grant would otherwise still be honored.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const outcome = @import("../base/outcome.zig");
const principal_model = @import("../principal/principal.zig");
const provenance_model = @import("../provenance/provenance.zig");

const types = @import("types.zig");
const Operation = types.Operation;
const OperationSet = types.OperationSet;
const ResourceSelector = types.ResourceSelector;
const RevocationBehavior = types.RevocationBehavior;
const Constraints = types.Constraints;
const RateLimit = types.RateLimit;
const UseContext = types.UseContext;
const Capability = types.Capability;
const Handle = types.Handle;
const Grant = types.Grant;
const Refusal = @import("errors.zig").Refusal;
const DomainError = outcome.DomainError;

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

    /// The furthest wall time ever seen, which only advances. Expiry is judged
    /// against this rather than the raw clock, so a backward wall-clock jump
    /// cannot revive a grant that has already expired.
    wall_floor: time.Timestamp = .epoch,

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
        owned.model_restrictions = try store.ownTextList(constraints.model_restrictions);
        return owned;
    }

    /// Issues a grant and returns a handle for the holder.
    ///
    /// The issuer must itself be able to act. Issuing from a revoked or expired
    /// principal would create authority that outlives the authority to create
    /// it.
    pub fn issue(store: *Store, grant: Grant) !Handle {
        // Authority cannot be minted from unvalidated untrusted input. A request
        // carrying model-output or external provenance must have been validated
        // for `.capability_request` first.
        if (!grant.provenance.permits(.capability_request)) return error.Unauthorized;

        const issuer = try store.principals.authorize(grant.issuer);
        const holder = try store.principals.authorize(grant.holder);

        // Authority stays within the issuer's policy domain unless the grant
        // explicitly reaches across it.
        if (!grant.constraints.permit_cross_domain and
            !std.mem.eql(u8, issuer.policy_domain, holder.policy_domain))
        {
            return store.refuse(.cross_domain);
        }

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
            .rate_window_started_at = store.clock.wall(),
            .rate_uses_in_window = 0,
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
        const recipient = try store.principals.authorize(new_holder);

        // A delegation must not exceed the parent in any dimension.
        if (!operations.subsetOf(parent.operations)) return store.refuse(.delegation_would_widen);
        if (!parent.resource.covers(resource)) return store.refuse(.delegation_would_widen);
        if (widensExpiry(parent.constraints, constraints)) return store.refuse(.delegation_would_widen);
        if (widensMonetaryLimit(parent.constraints, constraints)) return store.refuse(.delegation_would_widen);
        if (constraints.delegation_depth >= parent.constraints.delegation_depth) {
            return store.refuse(.delegation_would_widen);
        }
        if (constraints.permit_cross_domain and !parent.constraints.permit_cross_domain) {
            return store.refuse(.delegation_would_widen);
        }
        // A restricted parent cannot be delegated to a broader model set; a child
        // that lifts the restriction, or names a model the parent did not, widens.
        if (parent.constraints.model_restrictions.len != 0) {
            if (constraints.model_restrictions.len == 0) return store.refuse(.delegation_would_widen);
            for (constraints.model_restrictions) |model| {
                if (!containsText(parent.constraints.model_restrictions, model)) {
                    return store.refuse(.delegation_would_widen);
                }
            }
        }
        // A rate limit cannot be dropped or loosened by delegation.
        if (parent.constraints.rate_limit) |parent_rate| {
            const child_rate = constraints.rate_limit orelse return store.refuse(.delegation_would_widen);
            if (child_rate.max_uses > parent_rate.max_uses) return store.refuse(.delegation_would_widen);
            if (child_rate.window.nanoseconds < parent_rate.window.nanoseconds) {
                return store.refuse(.delegation_would_widen);
            }
        }
        // Handing authority to a holder in another domain crosses a domain, so it
        // needs the same explicit permission an original cross-domain grant does.
        const delegator = try store.principals.authorize(parent.holder);
        if (!constraints.permit_cross_domain and
            !std.mem.eql(u8, delegator.policy_domain, recipient.policy_domain))
        {
            return store.refuse(.cross_domain);
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
            .rate_window_started_at = store.clock.wall(),
            .rate_uses_in_window = 0,
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
        // Expiry must not run backwards: track the furthest time ever seen and
        // judge expiry against it, so a clock rolled back below a grant's expiry
        // cannot bring the grant back to life.
        if (now.isAfter(store.wall_floor)) store.wall_floor = now;

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
            if (!expires_at.isAfter(store.wall_floor)) return store.refuse(.expired);
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

        if (record.constraints.model_restrictions.len != 0) {
            const model = context.model orelse return store.refuse(.model_not_permitted);
            if (!containsText(record.constraints.model_restrictions, model)) {
                return store.refuse(.model_not_permitted);
            }
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

        // A rolling-window ceiling, spent here rather than in `check` because it
        // depends on the passage of time and on prior uses actually committing.
        // The window resets once its duration has elapsed since it opened.
        if (entry.constraints.rate_limit) |rate| {
            const now = store.clock.wall();
            const elapsed = now.since(entry.rate_window_started_at);
            if (elapsed.nanoseconds >= rate.window.nanoseconds) {
                entry.rate_window_started_at = now;
                entry.rate_uses_in_window = 0;
            }
            if (entry.rate_uses_in_window >= rate.max_uses) return store.refuse(.rate_limited);
            entry.rate_uses_in_window += 1;
        }

        entry.invocations_used += 1;
        store.last_refusal = null;
        return record;
    }

    /// Withdraws a grant. Outstanding handles become stale immediately.
    ///
    /// Delegations below this grant are withdrawn with it: authority that was
    /// derived from a withdrawn grant cannot outlive it. The whole delegation
    /// subtree is revoked, not just the immediate children — a grandchild grant
    /// derived from a withdrawn ancestor must not survive, or revocation would
    /// fail to contain delegated authority.
    ///
    /// The sweep is a fixpoint over the entry table rather than a recursive walk
    /// so it allocates nothing: revocation is a containment action that must
    /// succeed even under memory pressure. Each pass revokes any grant whose
    /// parent is now revoked; passes repeat until one changes nothing. The pass
    /// count is bounded by the delegation depth, and the table shrinks its set of
    /// live descendants every pass, so it terminates.
    pub fn revoke(store: *Store, id: identity.CapabilityId) DomainError!void {
        const root = store.entries.getPtr(id.value) orelse return error.Unauthorized;
        if (root.revoked) return; // Idempotent.
        root.revoked = true;
        root.generation += 1;

        var changed = true;
        while (changed) {
            changed = false;
            var iterator = store.entries.valueIterator();
            while (iterator.next()) |candidate| {
                if (candidate.revoked) continue;
                if (candidate.delegated_from.eql(.none)) continue;
                const parent = store.entries.get(candidate.delegated_from.value) orelse continue;
                if (parent.revoked) {
                    candidate.revoked = true;
                    candidate.generation += 1;
                    changed = true;
                }
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
pub fn permittedInvocations(constraints: Constraints) ?u32 {
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
