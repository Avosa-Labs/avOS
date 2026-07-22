//! Endpoints: the devices and clients authorized to present a session.
//!
//! An endpoint is a principal in its own right. Being able to render a session
//! is not the same as being able to act in it, and the two are separate grants:
//! a room display may show a task without being able to approve anything, and a
//! borrowed laptop may be trusted for an hour rather than indefinitely.
//!
//! Revocation takes effect on the next operation, not the next reconnection. An
//! endpoint that has been withdrawn while holding an open session is withdrawn
//! now, because the reason for withdrawing it is usually that it is no longer
//! in the owner's hands.

const std = @import("std");
const core = @import("core");

const identity = core.identity;
const time = core.time;
const outcome_model = core.outcome;

const DomainError = outcome_model.DomainError;

pub const Error = error{
    UnknownEndpoint,
    /// The endpoint may present but not act.
    InputNotPermitted,
    /// The endpoint's trust has lapsed or been withdrawn.
    NotTrusted,
    /// The endpoint is not associated with this human.
    WrongHuman,
    InvalidDeclaration,
};

pub const max_name_bytes: usize = 128;

/// What an endpoint is permitted to do with a session.
///
/// Presentation and input are separate because they carry different risk. An
/// endpoint that can only present leaks what is on screen if it is compromised;
/// one that can send input can act as the human.
pub const Permissions = struct {
    /// May render the session.
    may_present: bool = true,
    /// May send input, which means acting as the authenticated human.
    may_send_input: bool = false,
    /// May decide approvals. Narrower than input: a shared screen might accept
    /// typing without being somewhere a person should authorize a payment.
    may_approve: bool = false,

    /// Presentation only, the safest default for an endpoint whose physical
    /// surroundings are not known.
    pub const present_only: Permissions = .{};

    /// Everything, for an endpoint the human is holding.
    pub const full: Permissions = .{
        .may_present = true,
        .may_send_input = true,
        .may_approve = true,
    };

    /// An endpoint that cannot present cannot usefully do anything else, so a
    /// permission set claiming otherwise is malformed rather than merely odd.
    pub fn isCoherent(permissions: Permissions) bool {
        if (permissions.may_present) return true;
        return !permissions.may_send_input and !permissions.may_approve;
    }
};

pub const Status = enum {
    trusted,
    /// Withdrawn by the human. Terminal.
    revoked,

    pub fn isTerminal(status: Status) bool {
        return status == .revoked;
    }
};

pub const Endpoint = struct {
    /// The endpoint's own principal.
    id: identity.PrincipalId,
    /// The human this endpoint presents a session for.
    human: identity.PrincipalId,
    /// Metadata for the endpoints surface. Never authorization identity.
    name: []const u8,
    permissions: Permissions,
    status: Status,
    /// When trust lapses. Null means it persists until revoked.
    trusted_until: ?time.Timestamp,
    /// Incremented on revocation so a session token minted earlier is stale.
    generation: u64,

    /// Whether this endpoint may act at all right now.
    pub fn isTrusted(endpoint: Endpoint, now: time.Timestamp) bool {
        if (endpoint.status.isTerminal()) return false;
        if (endpoint.trusted_until) |until| {
            if (!until.isAfter(now)) return false;
        }
        return true;
    }
};

pub const Declaration = struct {
    human: identity.PrincipalId,
    name: []const u8,
    permissions: Permissions = .present_only,
    trusted_until: ?time.Timestamp = null,
};

/// The endpoints authorized for this host.
///
/// Ownership: the registry owns each record and the names it copies. `deinit`
/// releases both.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    clock: time.Clock,
    entries: std.AutoHashMapUnmanaged(u128, Endpoint) = .empty,

    pub fn init(gpa: std.mem.Allocator, ids: *identity.Source, clock: time.Clock) Registry {
        return .{ .gpa = gpa, .ids = ids, .clock = clock };
    }

    pub fn deinit(registry: *Registry) void {
        var iterator = registry.entries.valueIterator();
        while (iterator.next()) |endpoint| registry.gpa.free(endpoint.name);
        registry.entries.deinit(registry.gpa);
        registry.* = undefined;
    }

    pub fn enrol(registry: *Registry, declaration: Declaration) !identity.PrincipalId {
        if (declaration.name.len == 0 or declaration.name.len > max_name_bytes) {
            return error.InvalidDeclaration;
        }
        if (declaration.human.isNone()) return error.InvalidDeclaration;
        if (!declaration.permissions.isCoherent()) return error.InvalidDeclaration;
        if (declaration.trusted_until) |until| {
            if (!until.isAfter(registry.clock.wall())) return error.InvalidDeclaration;
        }

        const id = registry.ids.next(identity.PrincipalId);
        const name = try registry.gpa.dupe(u8, declaration.name);
        errdefer registry.gpa.free(name);

        try registry.entries.put(registry.gpa, id.value, .{
            .id = id,
            .human = declaration.human,
            .name = name,
            .permissions = declaration.permissions,
            .status = .trusted,
            .trusted_until = declaration.trusted_until,
            .generation = 0,
        });
        return id;
    }

    pub fn lookup(registry: Registry, id: identity.PrincipalId) ?Endpoint {
        return registry.entries.get(id.value);
    }

    /// Confirms an endpoint may perform an operation for a human.
    ///
    /// Checked on every operation rather than at connection time: an endpoint
    /// revoked mid-session must stop now, and the reason it was revoked is
    /// usually that it is no longer where its owner thinks it is.
    pub fn authorize(
        registry: Registry,
        id: identity.PrincipalId,
        human: identity.PrincipalId,
        needed: enum { present, input, approve },
    ) Error!Endpoint {
        const endpoint = registry.entries.get(id.value) orelse return error.UnknownEndpoint;
        if (!endpoint.human.eql(human)) return error.WrongHuman;
        if (!endpoint.isTrusted(registry.clock.wall())) return error.NotTrusted;

        const permitted = switch (needed) {
            .present => endpoint.permissions.may_present,
            .input => endpoint.permissions.may_send_input,
            .approve => endpoint.permissions.may_approve,
        };
        if (!permitted) return error.InputNotPermitted;
        return endpoint;
    }

    /// Withdraws an endpoint. Terminal, and effective immediately.
    pub fn revoke(registry: *Registry, id: identity.PrincipalId) Error!void {
        const entry = registry.entries.getPtr(id.value) orelse return error.UnknownEndpoint;
        if (entry.status == .revoked) return;
        entry.status = .revoked;
        entry.generation += 1;
    }

    pub fn count(registry: Registry) usize {
        return registry.entries.count();
    }
};

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: Registry,
    human: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) void {
        fixture.* = .{
            .ids = .initDeterministic(4242),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .human = .{ .value = 1 },
        };
        fixture.registry = .init(gpa, &fixture.ids, fixture.manual.clock());
    }

    fn deinit(fixture: *Fixture) void {
        fixture.registry.deinit();
    }
};

test "presenting a session is not the same as acting in it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const display = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Room display",
        .permissions = .present_only,
    });

    _ = try fixture.registry.authorize(display, fixture.human, .present);
    try std.testing.expectError(
        error.InputNotPermitted,
        fixture.registry.authorize(display, fixture.human, .input),
    );
    try std.testing.expectError(
        error.InputNotPermitted,
        fixture.registry.authorize(display, fixture.human, .approve),
    );
}

test "input and approval are separate grants" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A shared screen may accept typing without being somewhere a person
    // should authorize a payment.
    const shared = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Shared desktop",
        .permissions = .{ .may_present = true, .may_send_input = true, .may_approve = false },
    });

    _ = try fixture.registry.authorize(shared, fixture.human, .input);
    try std.testing.expectError(
        error.InputNotPermitted,
        fixture.registry.authorize(shared, fixture.human, .approve),
    );
}

test "a revoked endpoint loses access on the next operation, not the next connection" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const laptop = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Laptop",
        .permissions = .full,
    });
    _ = try fixture.registry.authorize(laptop, fixture.human, .input);

    try fixture.registry.revoke(laptop);

    try std.testing.expectError(
        error.NotTrusted,
        fixture.registry.authorize(laptop, fixture.human, .present),
    );
    try std.testing.expectEqual(@as(u64, 1), fixture.registry.lookup(laptop).?.generation);
}

test "revocation is terminal and idempotent" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const laptop = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Laptop",
        .permissions = .full,
    });

    try fixture.registry.revoke(laptop);
    try fixture.registry.revoke(laptop);
    // The generation moves once, so a token minted before the revocation is
    // stale exactly once rather than repeatedly invalidated.
    try std.testing.expectEqual(@as(u64, 1), fixture.registry.lookup(laptop).?.generation);
}

test "trust that lapses stops working without anyone revoking it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const borrowed = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Borrowed laptop",
        .permissions = .full,
        .trusted_until = .fromSeconds(1_600),
    });

    _ = try fixture.registry.authorize(borrowed, fixture.human, .input);
    fixture.manual.advance(.fromSeconds(1_000));

    try std.testing.expectError(
        error.NotTrusted,
        fixture.registry.authorize(borrowed, fixture.human, .input),
    );
    // Still trusted in status; it is the window that closed.
    try std.testing.expectEqual(Status.trusted, fixture.registry.lookup(borrowed).?.status);
}

test "an endpoint enrolled for one human cannot present another's session" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const laptop = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Laptop",
        .permissions = .full,
    });

    const other_human: identity.PrincipalId = .{ .value = 99 };
    try std.testing.expectError(
        error.WrongHuman,
        fixture.registry.authorize(laptop, other_human, .present),
    );
}

test "an unknown endpoint is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try std.testing.expectError(
        error.UnknownEndpoint,
        fixture.registry.authorize(.{ .value = 0xdead }, fixture.human, .present),
    );
}

test "an incoherent permission set is refused at enrolment" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // Acting without presenting is not a meaningful endpoint.
    try std.testing.expectError(error.InvalidDeclaration, fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Headless",
        .permissions = .{ .may_present = false, .may_send_input = true },
    }));

    try std.testing.expect(Permissions.present_only.isCoherent());
    try std.testing.expect(Permissions.full.isCoherent());
    try std.testing.expect((Permissions{ .may_present = false }).isCoherent());
}

test "an endpoint must name a human and carry a bounded name" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try std.testing.expectError(error.InvalidDeclaration, fixture.registry.enrol(.{
        .human = .none,
        .name = "Laptop",
    }));
    try std.testing.expectError(error.InvalidDeclaration, fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "",
    }));

    const overlong: [max_name_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidDeclaration, fixture.registry.enrol(.{
        .human = fixture.human,
        .name = &overlong,
    }));
}

test "trust that has already lapsed cannot be granted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try std.testing.expectError(error.InvalidDeclaration, fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Stale",
        .trusted_until = .fromSeconds(500),
    }));
}

test "revoking one endpoint leaves the others working" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const phone = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Phone",
        .permissions = .full,
    });
    const laptop = try fixture.registry.enrol(.{
        .human = fixture.human,
        .name = "Laptop",
        .permissions = .full,
    });

    try fixture.registry.revoke(laptop);

    _ = try fixture.registry.authorize(phone, fixture.human, .input);
    try std.testing.expectError(
        error.NotTrusted,
        fixture.registry.authorize(laptop, fixture.human, .present),
    );
}
