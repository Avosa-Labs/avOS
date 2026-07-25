//! The single doorway every runtime crosses to reach a host capability, so that
//! "may this guest touch this host resource" is answered one way for native, wasm,
//! Android, and web alike — by the capability the guest actually holds, never by the
//! runtime it happens to run under.
//!
//! A runtime is an adapter, not an authority. Whatever a guest declares about itself
//! — a wasm import section, an Android permission, a web origin — is a request, and a
//! request is not a grant. Without one boundary, each runtime answers that request
//! its own way: one checks a hand-built grant, one denies every import wholesale, one
//! checks nothing at all. That is four chances to get authorization wrong and four
//! places to fix it when the model changes. This is the one place. A guest presents
//! the capability handle it was given, names the operation and the resource kind it
//! wants, and the bridge asks the capability store whether that handle authorizes
//! exactly that — and if it does not, the request is denied here, before the runtime
//! touches the host at all.
//!
//! The bridge holds no authority of its own; it consults the store and reports the
//! answer. It counts crossings and denials so the boundary is observable — a runtime
//! generating denials is a runtime reaching for what it was not given, which is worth
//! seeing rather than losing in each adapter. Metering and journaling of the crossing
//! belong to the trusted services above, which call *into* a runtime; a runtime never
//! reaches up into them, so this boundary depends only on the core capability model.

const std = @import("std");
const core = @import("core");

const capability = core.capability;
const identity = core.identity;

pub const Handle = capability.Handle;
pub const Operation = capability.Operation;
pub const Store = capability.Store;

/// A guest's request to cross into a host capability.
pub const Request = struct {
    /// The principal the guest acts as. The capability must be held by exactly this
    /// principal, so a stolen handle is useless to anyone but its holder.
    holder: identity.PrincipalId,
    /// The capability handle the guest presents. Authority comes from this and
    /// nothing else the guest can assert.
    handle: Handle,
    /// The operation the guest wants to perform.
    operation: Operation,
    /// The kind of host resource it names, e.g. "calendar", "filesystem",
    /// "network". Matched against what the capability covers.
    resource_kind: []const u8,
    /// A specific resource within the kind, or none to name the kind at large.
    resource: identity.ResourceId = .none,
};

/// Why a crossing was denied. A coarse, guest-facing reason: the guest learns it may
/// not proceed and roughly why, while the store's ledger keeps the precise refusal.
pub const Denial = enum {
    /// The handle names no authority for this operation or resource.
    unauthorized,
    /// The capability was revoked.
    revoked,
    /// The capability's validity window has passed.
    expired,
    /// A declared constraint — a task binding, a limit, a confirmation — rejected
    /// this particular use.
    constraint,
    /// A budget bound to the capability is spent.
    budget_exhausted,
    /// The handle failed an integrity or generation check.
    integrity,
    /// The capability service is not reachable to answer.
    unavailable,
    /// The request itself is malformed.
    invalid,
    /// The store refused for a reason not otherwise distinguished.
    refused,
};

/// The bridge's answer to a crossing.
pub const Decision = union(enum) {
    /// The crossing is authorized; the resolved capability is returned so the
    /// runtime can honour any constraints it carries.
    allow: capability.Capability,
    /// The crossing is denied, for this reason.
    deny: Denial,

    pub fn allowed(decision: Decision) bool {
        return decision == .allow;
    }
};

/// Maps the capability store's error to the guest-facing denial. Several store
/// errors collapse onto one denial deliberately — the guest learns it may not
/// proceed, the ledger retains which check failed.
fn denialFor(err: core.outcome.DomainError) Denial {
    return switch (err) {
        error.Unauthorized => .unauthorized,
        error.CapabilityRevoked => .revoked,
        error.CapabilityExpired => .expired,
        error.ConstraintViolation, error.Cancelled, error.DeadlineExceeded => .constraint,
        error.BudgetExhausted => .budget_exhausted,
        error.IntegrityFailure => .integrity,
        error.Unavailable => .unavailable,
        error.InvalidInput => .invalid,
        else => .refused,
    };
}

/// The one boundary every runtime crosses to reach a host capability.
///
/// Ownership: the bridge borrows the capability store; the trusted control plane
/// owns it. The bridge adds only its own crossing counters.
pub const Bridge = struct {
    store: *Store,
    /// Crossings attempted, whatever the outcome.
    crossings: u64 = 0,
    /// Crossings denied. A rising count is a runtime reaching for authority it was
    /// not granted — the signal the single boundary exists to make visible.
    denials: u64 = 0,

    pub fn init(store: *Store) Bridge {
        return .{ .store = store };
    }

    /// Decides one crossing.
    ///
    /// The handle is used, not merely checked: a successful crossing spends against
    /// any invocation limit the capability carries, so a guest cannot exceed a
    /// bounded grant by crossing repeatedly. A denial spends nothing. Whatever the
    /// store decides, this returns a decision rather than an error, so a denied
    /// crossing is a normal outcome a runtime handles, never a fault that escapes.
    pub fn cross(bridge: *Bridge, request: Request) Decision {
        bridge.crossings += 1;
        const granted = bridge.store.use(request.handle, .{
            .holder = request.holder,
            .operation = request.operation,
            .resource = .{ .kind = request.resource_kind, .resource = request.resource },
        }) catch |err| {
            bridge.denials += 1;
            return .{ .deny = denialFor(err) };
        };
        return .{ .allow = granted };
    }

    /// Whether a crossing would be authorized, without spending against the
    /// capability. For a runtime that wants to check admissibility before doing
    /// setup work it would have to undo on denial.
    pub fn wouldAllow(bridge: *Bridge, request: Request) bool {
        _ = bridge.store.check(request.handle, .{
            .holder = request.holder,
            .operation = request.operation,
            .resource = .{ .kind = request.resource_kind, .resource = request.resource },
        }) catch return false;
        return true;
    }
};

// --- Tests ---

const testing = std.testing;
const time = core.time;
const principal_model = core.principal;

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal_model.Registry,
    store: Store,
    operator: identity.PrincipalId,
    guest: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        fixture.* = .{
            .ids = .initDeterministic(20260722),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .operator = .none,
            .guest = .none,
        };
        fixture.registry = .init(gpa, &fixture.ids, fixture.manual.clock());
        fixture.store = .init(gpa, &fixture.ids, fixture.manual.clock(), &fixture.registry);
        fixture.operator = try fixture.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        });
        fixture.guest = try fixture.registry.enroll(.{
            .kind = .agent,
            .display_name = "guest",
            .policy_domain = "local",
            .expires_at = .fromSeconds(100_000),
            .issuer = fixture.operator,
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    /// Issues a handle granting `operations` on a resource kind to the guest.
    fn grant(fixture: *Fixture, kind: []const u8, operations: capability.OperationSet) !Handle {
        return fixture.store.issue(.{
            .issuer = fixture.operator,
            .holder = fixture.guest,
            .resource = .{ .kind = kind },
            .operations = operations,
        });
    }
};

fn only(operation: Operation) capability.OperationSet {
    var set: capability.OperationSet = .initEmpty();
    set.insert(operation);
    return set;
}

test "a crossing the capability covers is allowed" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grant("calendar", only(.read));
    var bridge = Bridge.init(&fixture.store);
    const decision = bridge.cross(.{ .holder = fixture.guest, .handle = handle, .operation = .read, .resource_kind = "calendar" });
    try testing.expect(decision.allowed());
    try testing.expectEqual(@as(u64, 0), bridge.denials);
}

test "a crossing for an operation the capability lacks is denied as unauthorized" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // Granted read, asks to write.
    const handle = try fixture.grant("calendar", only(.read));
    var bridge = Bridge.init(&fixture.store);
    const decision = bridge.cross(.{ .holder = fixture.guest, .handle = handle, .operation = .write, .resource_kind = "calendar" });
    try testing.expectEqual(Denial.unauthorized, decision.deny);
    try testing.expectEqual(@as(u64, 1), bridge.denials);
}

test "a crossing for a resource kind the capability does not name is denied" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grant("calendar", only(.read));
    var bridge = Bridge.init(&fixture.store);
    // Right operation, wrong resource kind.
    const decision = bridge.cross(.{ .holder = fixture.guest, .handle = handle, .operation = .read, .resource_kind = "contacts" });
    try testing.expectEqual(Denial.unauthorized, decision.deny);
}

test "a revoked capability is denied at the boundary" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grant("calendar", only(.read));
    try fixture.store.revoke(handle.id);
    var bridge = Bridge.init(&fixture.store);
    // The retained handle carries the pre-revocation generation, so the store sees a
    // stale handle — an integrity failure — which the boundary denies all the same.
    const decision = bridge.cross(.{ .holder = fixture.guest, .handle = handle, .operation = .read, .resource_kind = "calendar" });
    try testing.expect(!decision.allowed());
    try testing.expectEqual(Denial.integrity, decision.deny);
}

test "wouldAllow reports admissibility without spending the capability" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grant("network", only(.read));
    var bridge = Bridge.init(&fixture.store);
    try testing.expect(bridge.wouldAllow(.{ .holder = fixture.guest, .handle = handle, .operation = .read, .resource_kind = "network" }));
    try testing.expect(!bridge.wouldAllow(.{ .holder = fixture.guest, .handle = handle, .operation = .write, .resource_kind = "network" }));
    // Checking did not count as a crossing.
    try testing.expectEqual(@as(u64, 0), bridge.crossings);
}
