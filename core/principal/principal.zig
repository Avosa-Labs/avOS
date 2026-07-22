//! Principals: every entity that can act.
//!
//! Humans, agents, applications, services, organizations, devices, and sessions
//! are all principals. They are not tiers of trust — an agent is not a lesser
//! human, and authority never follows from kind alone. Kind determines which
//! rules apply to a principal's lifecycle, not what it may do; that comes from
//! capabilities.
//!
//! Two rules govern every lookup here. A revoked principal fails closed, so a
//! withdrawal takes effect on the next operation rather than the next restart.
//! And a display name is metadata: it is never compared, never resolved, and
//! never used as authorization identity.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const outcome = @import("../base/outcome.zig");

const DomainError = outcome.DomainError;

pub const Kind = enum {
    human,
    agent,
    application,
    service,
    organization,
    device,
    session,

    /// Whether a principal of this kind may hold authority without a human
    /// somewhere in its delegation chain. Only a human originates authority;
    /// everything else exercises authority on someone's behalf.
    pub fn originatesAuthority(kind: Kind) bool {
        return switch (kind) {
            .human, .organization => true,
            .agent, .application, .service, .device, .session => false,
        };
    }

    /// Whether a principal of this kind must declare an expiration.
    ///
    /// An agent or session that outlives its purpose is standing authority
    /// nobody decided to grant, so both must say when they end.
    pub fn requiresExpiration(kind: Kind) bool {
        return switch (kind) {
            .agent, .session => true,
            .human, .application, .service, .organization, .device => false,
        };
    }
};

pub const Status = enum {
    /// May act, subject to its capabilities.
    active,
    /// Temporarily barred; may be reactivated.
    suspended,
    /// Permanently barred. Terminal.
    revoked,

    pub fn isTerminal(status: Status) bool {
        return status == .revoked;
    }
};

/// How a principal came to exist. Recorded so the ledger can answer who
/// introduced an actor into the system.
pub const Provenance = struct {
    /// The principal that created this one. `none` for a root human enrolled
    /// during device setup.
    issuer: identity.PrincipalId,
    created_at: time.Timestamp,
};

pub const Principal = struct {
    id: identity.PrincipalId,
    kind: Kind,
    status: Status,
    provenance: Provenance,
    /// Non-authoritative label for interface surfaces. Never compared, never
    /// resolved, never used to authorize.
    display_name: []const u8,
    /// Policy domain this principal belongs to. Capabilities do not cross
    /// domains without an explicit grant.
    policy_domain: []const u8,
    /// When this principal ceases to be valid. Required for kinds that
    /// `Kind.requiresExpiration`.
    expires_at: ?time.Timestamp,
    /// Incremented on every revocation so a handle minted before a revocation
    /// cannot be replayed after one.
    generation: u64,

    /// Whether this principal may act at `now`.
    ///
    /// Expiry is evaluated against the wall clock because validity is stated in
    /// real time. A principal that is suspended, revoked, or past its
    /// expiration cannot act, and each condition reports distinctly so the
    /// ledger records why.
    pub fn authorize(principal: Principal, now: time.Timestamp) DomainError!void {
        switch (principal.status) {
            .active => {},
            .suspended => return error.Unauthorized,
            .revoked => return error.Unauthorized,
        }
        if (principal.expires_at) |expiry| {
            if (!expiry.isAfter(now)) return error.CapabilityExpired;
        }
    }

    pub fn isActive(principal: Principal, now: time.Timestamp) bool {
        principal.authorize(now) catch return false;
        return true;
    }
};

/// Declaration used to enroll a principal. Separated from `Principal` so the
/// registry, not the caller, assigns identity, generation, and provenance.
pub const Declaration = struct {
    kind: Kind,
    display_name: []const u8,
    policy_domain: []const u8,
    expires_at: ?time.Timestamp = null,
    /// The principal enrolling this one. `none` only for a root human.
    issuer: identity.PrincipalId = .none,
};

/// The authoritative set of principals on this host.
///
/// Ownership: the registry owns its map and the strings it copies from each
/// declaration. `deinit` releases both. Lookups return a copy of the record, so
/// a caller cannot mutate registry state by holding a reference.
///
/// Lookup is expected O(1): it sits on the authorization path of every
/// privileged operation.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    clock: time.Clock,
    entries: std.AutoHashMapUnmanaged(u128, Principal) = .empty,

    pub fn init(gpa: std.mem.Allocator, ids: *identity.Source, clock: time.Clock) Registry {
        return .{ .gpa = gpa, .ids = ids, .clock = clock };
    }

    pub fn deinit(registry: *Registry) void {
        var iterator = registry.entries.valueIterator();
        while (iterator.next()) |principal| {
            registry.gpa.free(principal.display_name);
            registry.gpa.free(principal.policy_domain);
        }
        registry.entries.deinit(registry.gpa);
        registry.* = undefined;
    }

    /// Enrolls a principal and returns its identifier.
    ///
    /// Rejects a declaration that would create standing authority nobody
    /// granted: a kind requiring an expiration must have one, and a non-root
    /// principal must name its issuer.
    pub fn enroll(registry: *Registry, declaration: Declaration) !identity.PrincipalId {
        if (declaration.kind.requiresExpiration() and declaration.expires_at == null) {
            return error.InvalidInput;
        }
        if (!declaration.kind.originatesAuthority() and declaration.issuer.isNone()) {
            return error.InvalidInput;
        }
        if (declaration.expires_at) |expiry| {
            if (!expiry.isAfter(registry.clock.wall())) return error.InvalidInput;
        }

        const id = registry.ids.next(identity.PrincipalId);

        const display_name = try registry.gpa.dupe(u8, declaration.display_name);
        errdefer registry.gpa.free(display_name);
        const policy_domain = try registry.gpa.dupe(u8, declaration.policy_domain);
        errdefer registry.gpa.free(policy_domain);

        try registry.entries.put(registry.gpa, id.value, .{
            .id = id,
            .kind = declaration.kind,
            .status = .active,
            .provenance = .{
                .issuer = declaration.issuer,
                .created_at = registry.clock.wall(),
            },
            .display_name = display_name,
            .policy_domain = policy_domain,
            .expires_at = declaration.expires_at,
            .generation = 0,
        });
        return id;
    }

    pub fn lookup(registry: Registry, id: identity.PrincipalId) ?Principal {
        return registry.entries.get(id.value);
    }

    /// Resolves a principal and confirms it may act now.
    ///
    /// This is the call an authorization path makes. An unknown identifier is
    /// reported as unauthorized rather than as a lookup miss, so probing cannot
    /// distinguish "no such principal" from "not permitted".
    pub fn authorize(registry: Registry, id: identity.PrincipalId) DomainError!Principal {
        const principal = registry.entries.get(id.value) orelse return error.Unauthorized;
        try principal.authorize(registry.clock.wall());
        return principal;
    }

    /// Withdraws a principal permanently and bumps its generation.
    ///
    /// Revocation is terminal: a revoked principal is never reactivated,
    /// because reusing an identity would let old records describe a different
    /// actor than the one that acted.
    pub fn revoke(registry: *Registry, id: identity.PrincipalId) DomainError!void {
        const entry = registry.entries.getPtr(id.value) orelse return error.Unauthorized;
        if (entry.status == .revoked) return; // Idempotent.
        entry.status = .revoked;
        entry.generation += 1;
    }

    pub fn suspendPrincipal(registry: *Registry, id: identity.PrincipalId) DomainError!void {
        const entry = registry.entries.getPtr(id.value) orelse return error.Unauthorized;
        if (entry.status.isTerminal()) return error.Conflict;
        entry.status = .suspended;
    }

    pub fn reinstate(registry: *Registry, id: identity.PrincipalId) DomainError!void {
        const entry = registry.entries.getPtr(id.value) orelse return error.Unauthorized;
        if (entry.status.isTerminal()) return error.Conflict;
        entry.status = .active;
    }

    pub fn count(registry: Registry) usize {
        return registry.entries.count();
    }
};

const testing = struct {
    fn registry(gpa: std.mem.Allocator, ids: *identity.Source, manual: *time.ManualClock) Registry {
        return .init(gpa, ids, manual.clock());
    }
};

test "a human enrolls without an issuer and an agent does not" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(1);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    const human = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });

    // An agent without an issuer would hold authority nobody delegated.
    try std.testing.expectError(error.InvalidInput, registry.enroll(.{
        .kind = .agent,
        .display_name = "planner",
        .policy_domain = "local",
        .expires_at = .fromSeconds(2_000),
    }));

    _ = try registry.enroll(.{
        .kind = .agent,
        .display_name = "planner",
        .policy_domain = "local",
        .expires_at = .fromSeconds(2_000),
        .issuer = human,
    });
    try std.testing.expectEqual(@as(usize, 2), registry.count());
}

test "a temporary kind must declare an expiration" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(2);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    const human = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });

    for ([_]Kind{ .agent, .session }) |kind| {
        try std.testing.expectError(error.InvalidInput, registry.enroll(.{
            .kind = kind,
            .display_name = "temporary",
            .policy_domain = "local",
            .issuer = human,
        }));
    }
}

test "an expiration already in the past is rejected at enrollment" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(3);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    const human = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });
    try std.testing.expectError(error.InvalidInput, registry.enroll(.{
        .kind = .agent,
        .display_name = "stale",
        .policy_domain = "local",
        .expires_at = .fromSeconds(500),
        .issuer = human,
    }));
}

test "a revoked principal fails closed on the next operation" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(4);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    const human = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });
    _ = try registry.authorize(human);

    try registry.revoke(human);
    try std.testing.expectError(error.Unauthorized, registry.authorize(human));

    // Revocation is terminal; the principal cannot be brought back.
    try std.testing.expectError(error.Conflict, registry.reinstate(human));
}

test "revocation is idempotent and bumps the generation exactly once" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(5);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    const human = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });
    try std.testing.expectEqual(@as(u64, 0), registry.lookup(human).?.generation);

    try registry.revoke(human);
    try registry.revoke(human);
    try std.testing.expectEqual(@as(u64, 1), registry.lookup(human).?.generation);
}

test "an expired agent cannot act even while its status is active" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(6);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    const human = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });
    const agent = try registry.enroll(.{
        .kind = .agent,
        .display_name = "planner",
        .policy_domain = "local",
        .expires_at = .fromSeconds(1_060),
        .issuer = human,
    });

    _ = try registry.authorize(agent);
    manual.advance(.fromSeconds(120));

    try std.testing.expectEqual(Status.active, registry.lookup(agent).?.status);
    try std.testing.expectError(error.CapabilityExpired, registry.authorize(agent));
}

test "suspension bars action and reinstatement restores it" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(7);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    const human = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });

    try registry.suspendPrincipal(human);
    try std.testing.expectError(error.Unauthorized, registry.authorize(human));

    try registry.reinstate(human);
    _ = try registry.authorize(human);
}

test "an unknown principal is unauthorized rather than distinguishable" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(8);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    // Probing must not reveal whether an identifier names a real principal.
    const unknown: identity.PrincipalId = .{ .value = 0xdead_beef };
    try std.testing.expectError(error.Unauthorized, registry.authorize(unknown));
    try std.testing.expectEqual(@as(?Principal, null), registry.lookup(unknown));
}

test "display names are never identity" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(9);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));
    var registry = testing.registry(gpa, &ids, &manual);
    defer registry.deinit();

    // Two principals may share a display name and remain distinct actors.
    const first = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });
    const second = try registry.enroll(.{
        .kind = .human,
        .display_name = "operator",
        .policy_domain = "local",
    });

    try std.testing.expect(!first.eql(second));
    try std.testing.expectEqualStrings(
        registry.lookup(first).?.display_name,
        registry.lookup(second).?.display_name,
    );

    try registry.revoke(first);
    try std.testing.expectError(error.Unauthorized, registry.authorize(first));
    _ = try registry.authorize(second);
}

test "only humans and organizations originate authority" {
    for (std.enums.values(Kind)) |kind| {
        const expected = kind == .human or kind == .organization;
        try std.testing.expectEqual(expected, kind.originatesAuthority());
    }
}

test "enrollment survives allocation failure without corrupting the registry" {
    const gpa = std.testing.allocator;
    var ids: identity.Source = .initDeterministic(10);
    var manual: time.ManualClock = .init(.fromSeconds(1_000));

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 3 });
    var registry = Registry.init(failing.allocator(), &ids, manual.clock());
    defer registry.deinit();

    var enrolled: usize = 0;
    for (0..8) |_| {
        _ = registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        }) catch break;
        enrolled += 1;
    }

    // Whatever was enrolled before the failure must still be intact and
    // consistent with the registry's own count.
    try std.testing.expectEqual(enrolled, registry.count());
}
