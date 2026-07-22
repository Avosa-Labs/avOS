//! Principal, capability, and resource inspectors.
//!
//! These surfaces answer the questions a person needs answered to stay in
//! control: who is acting, what were they allowed to do, what did it cost, and
//! what can I withdraw. Each reads the authoritative record rather than a
//! summary, so what is shown is what the system would enforce.
//!
//! Nothing here can widen authority. The inspectors present and offer
//! revocation; issuing is a decision made in the control plane, and a surface
//! that could grant would be a second place authority comes from.

const std = @import("std");
const core = @import("core");
const design = @import("design");

const identity = core.identity;
const principal_model = core.principal;
const capability_model = core.capability;
const resource = core.resource;
const time = core.time;
const tokens = design.tokens;
const accessibility = design.accessibility;

pub const Error = error{
    NotAuthenticated,
    TooManyRows,
};

pub const max_rows: usize = 256;

/// A principal as the inspector presents it.
pub const PrincipalRow = struct {
    id: identity.PrincipalId,
    kind: principal_model.Kind,
    /// Metadata only. Never used to identify or authorize.
    display_name: []const u8,
    status: principal_model.Status,
    status_text: []const u8,
    status_colour: tokens.ColourRole,
    /// Whether this principal can act right now, which is not the same as its
    /// status: an active principal past its expiry cannot act.
    can_act: bool,
    /// Whether the user may withdraw this principal from here.
    revocable: bool,
    capability_count: usize,
};

/// A capability as the inspector presents it.
pub const CapabilityRow = struct {
    id: identity.CapabilityId,
    holder: identity.PrincipalId,
    issuer: identity.PrincipalId,
    resource_kind: []const u8,
    /// Operations in the grant, listed so the user reads what it permits rather
    /// than a count.
    operations: capability_model.OperationSet,
    /// Uses remaining, when the grant is limited.
    remaining_uses: ?u32,
    expires_at: ?time.Timestamp,
    /// Delegation distance from the originating grant.
    depth: u8,
    /// Whether this grant may be delegated further.
    delegable: bool,
    revoked: bool,
    status_text: []const u8,
    status_colour: tokens.ColourRole,
};

/// One principal's resource consumption.
pub const ResourceRow = struct {
    principal: identity.PrincipalId,
    task: identity.TaskId,
    current_bytes: usize,
    peak_bytes: usize,
    limit_bytes: usize,
    /// Proportion of the ceiling currently held, from 0 to 1.
    utilization: f32,
    /// Allocations the ceiling refused. Non-zero means the principal is being
    /// held back by its budget, which the user should be able to see.
    refusals: u64,
    status_text: []const u8,
    status_colour: tokens.ColourRole,
};

pub const Session = struct {
    authenticated: bool,
    human: identity.PrincipalId,
};

fn principalStatusText(record: principal_model.Principal, now: time.Timestamp) []const u8 {
    return switch (record.status) {
        .revoked => "Revoked",
        .suspended => "Suspended",
        .active => if (record.isActive(now)) "Active" else "Expired",
    };
}

fn principalStatusColour(record: principal_model.Principal, now: time.Timestamp) tokens.ColourRole {
    return switch (record.status) {
        .revoked => .status_denied,
        .suspended => .status_cancelled,
        .active => if (record.isActive(now)) .status_succeeded else .status_cancelled,
    };
}

/// Projects the principals this host knows about.
///
/// Caller owns the returned slice. A revoked principal is still listed: hiding
/// it would remove the record of something that acted, and the ledger would
/// then reference an actor the user cannot look up.
pub fn projectPrincipals(
    gpa: std.mem.Allocator,
    registry: *const principal_model.Registry,
    store: *const capability_model.Store,
    session: Session,
    now: time.Timestamp,
) ![]PrincipalRow {
    if (!session.authenticated) return error.NotAuthenticated;

    var rows: std.ArrayList(PrincipalRow) = .empty;
    errdefer rows.deinit(gpa);

    var iterator = registry.entries.valueIterator();
    while (iterator.next()) |record| {
        if (rows.items.len >= max_rows) return error.TooManyRows;
        try rows.append(gpa, .{
            .id = record.id,
            .kind = record.kind,
            .display_name = record.display_name,
            .status = record.status,
            .status_text = principalStatusText(record.*, now),
            .status_colour = principalStatusColour(record.*, now),
            .can_act = record.isActive(now),
            // A human cannot revoke themselves from here: doing so would leave
            // the session with no authority to undo it.
            .revocable = record.status != .revoked and !record.id.eql(session.human),
            .capability_count = countCapabilities(store, record.id),
        });
    }
    return rows.toOwnedSlice(gpa);
}

fn countCapabilities(store: *const capability_model.Store, holder: identity.PrincipalId) usize {
    var count: usize = 0;
    var iterator = store.entries.valueIterator();
    while (iterator.next()) |record| {
        if (record.holder.eql(holder) and !record.revoked) count += 1;
    }
    return count;
}

/// Projects the capabilities held on this host.
///
/// Caller owns the returned slice.
pub fn projectCapabilities(
    gpa: std.mem.Allocator,
    store: *const capability_model.Store,
    session: Session,
    now: time.Timestamp,
) ![]CapabilityRow {
    if (!session.authenticated) return error.NotAuthenticated;

    var rows: std.ArrayList(CapabilityRow) = .empty;
    errdefer rows.deinit(gpa);

    var iterator = store.entries.valueIterator();
    while (iterator.next()) |record| {
        if (rows.items.len >= max_rows) return error.TooManyRows;

        const expired = if (record.constraints.expires_at) |expiry|
            !expiry.isAfter(now)
        else
            false;

        const remaining: ?u32 = if (record.constraints.one_time)
            (if (record.invocations_used >= 1) 0 else 1)
        else if (record.constraints.invocation_limit) |limit|
            limit -| record.invocations_used
        else
            null;

        try rows.append(gpa, .{
            .id = record.id,
            .holder = record.holder,
            .issuer = record.issuer,
            .resource_kind = record.resource.kind,
            .operations = record.operations,
            .remaining_uses = remaining,
            .expires_at = record.constraints.expires_at,
            .depth = record.depth,
            .delegable = record.constraints.delegation_depth > 0,
            .revoked = record.revoked,
            .status_text = if (record.revoked)
                "Revoked"
            else if (expired)
                "Expired"
            else if (remaining != null and remaining.? == 0)
                "Used up"
            else
                "Active",
            .status_colour = if (record.revoked)
                .status_denied
            else if (expired or (remaining != null and remaining.? == 0))
                .status_cancelled
            else
                .status_succeeded,
        });
    }
    return rows.toOwnedSlice(gpa);
}

/// Projects resource consumption from live budgets.
///
/// Caller owns the returned slice. Utilization is computed here rather than
/// stored, so it cannot go stale relative to the budget it describes.
pub fn projectResources(
    gpa: std.mem.Allocator,
    budgets: []const resource.Budget,
    session: Session,
) ![]ResourceRow {
    if (!session.authenticated) return error.NotAuthenticated;

    var rows: std.ArrayList(ResourceRow) = .empty;
    errdefer rows.deinit(gpa);

    for (budgets) |budget| {
        if (rows.items.len >= max_rows) return error.TooManyRows;

        const utilization: f32 = if (budget.usage.limit_bytes == 0)
            0
        else
            @as(f32, @floatFromInt(budget.usage.current_bytes)) /
                @as(f32, @floatFromInt(budget.usage.limit_bytes));

        try rows.append(gpa, .{
            .principal = budget.attribution.principal,
            .task = budget.attribution.task,
            .current_bytes = budget.usage.current_bytes,
            .peak_bytes = budget.usage.peak_bytes,
            .limit_bytes = budget.usage.limit_bytes,
            .utilization = utilization,
            .refusals = budget.usage.refused_allocations,
            .status_text = if (budget.usage.refused_allocations > 0)
                "Held back by its budget"
            else if (utilization >= 0.9)
                "Near its limit"
            else
                "Within its budget",
            .status_colour = if (budget.usage.refused_allocations > 0)
                .status_denied
            else if (utilization >= 0.9)
                .status_awaiting_approval
            else
                .status_succeeded,
        });
    }
    return rows.toOwnedSlice(gpa);
}

/// The accessibility view of the principal inspector.
pub fn describePrincipals(
    gpa: std.mem.Allocator,
    rows: []const PrincipalRow,
) !accessibility.Surface {
    var elements: std.ArrayList(accessibility.Element) = .empty;
    errdefer elements.deinit(gpa);
    var order: std.ArrayList(usize) = .empty;
    errdefer order.deinit(gpa);

    try elements.append(gpa, .{ .role = .heading, .accessible_name = "Who can act" });

    for (rows) |row| {
        try order.append(gpa, elements.items.len);
        try elements.append(gpa, .{
            .role = .list_item,
            .accessible_name = row.display_name,
            .status = row.status_colour,
            .status_text = row.status_text,
        });
    }

    return .{
        .title = "Principals",
        .elements = try elements.toOwnedSlice(gpa),
        .focus_order = try order.toOwnedSlice(gpa),
    };
}

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal_model.Registry,
    store: capability_model.Store,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        fixture.* = .{
            .ids = .initDeterministic(3131),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .human = .none,
            .agent = .none,
        };
        const clock = fixture.manual.clock();
        fixture.registry = .init(gpa, &fixture.ids, clock);
        fixture.store = .init(gpa, &fixture.ids, clock, &fixture.registry);

        fixture.human = try fixture.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        });
        fixture.agent = try fixture.registry.enroll(.{
            .kind = .agent,
            .display_name = "calendar",
            .policy_domain = "local",
            .expires_at = .fromSeconds(5_000),
            .issuer = fixture.human,
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    fn session(fixture: *Fixture) Session {
        return .{ .authenticated = true, .human = fixture.human };
    }

    fn now(fixture: *Fixture) time.Timestamp {
        return fixture.manual.clock().wall();
    }

    fn readGrant(fixture: *Fixture) !capability_model.Handle {
        var operations: capability_model.OperationSet = .initEmpty();
        operations.insert(.read);
        return fixture.store.issue(.{
            .issuer = fixture.human,
            .holder = fixture.agent,
            .resource = .{ .kind = "calendar" },
            .operations = operations,
        });
    }
};

test "principals are listed with what they may do right now" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();
    _ = try fixture.readGrant();

    const rows = try projectPrincipals(
        gpa,
        &fixture.registry,
        &fixture.store,
        fixture.session(),
        fixture.now(),
    );
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| {
        try std.testing.expect(row.can_act);
        try std.testing.expectEqualStrings("Active", row.status_text);
        if (row.kind == .agent) try std.testing.expectEqual(@as(usize, 1), row.capability_count);
    }
}

test "an expired agent reads as expired even while its status is active" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    fixture.manual.advance(.fromSeconds(10_000));

    const rows = try projectPrincipals(
        gpa,
        &fixture.registry,
        &fixture.store,
        fixture.session(),
        fixture.now(),
    );
    defer gpa.free(rows);

    for (rows) |row| {
        if (row.kind != .agent) continue;
        // Status and ability to act are different questions, and the surface
        // answers the one the user is asking.
        try std.testing.expectEqual(principal_model.Status.active, row.status);
        try std.testing.expect(!row.can_act);
        try std.testing.expectEqualStrings("Expired", row.status_text);
    }
}

test "a revoked principal stays listed so the ledger remains readable" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.registry.revoke(fixture.agent);

    const rows = try projectPrincipals(
        gpa,
        &fixture.registry,
        &fixture.store,
        fixture.session(),
        fixture.now(),
    );
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| {
        if (row.kind != .agent) continue;
        try std.testing.expectEqualStrings("Revoked", row.status_text);
        try std.testing.expect(!row.revocable);
        try std.testing.expectEqual(tokens.ColourRole.status_denied, row.status_colour);
    }
}

test "the signed-in human cannot revoke themselves from the inspector" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const rows = try projectPrincipals(
        gpa,
        &fixture.registry,
        &fixture.store,
        fixture.session(),
        fixture.now(),
    );
    defer gpa.free(rows);

    for (rows) |row| {
        if (row.id.eql(fixture.human)) try std.testing.expect(!row.revocable);
        if (row.kind == .agent) try std.testing.expect(row.revocable);
    }
}

test "a capability shows what it permits and how much of it is left" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var send: capability_model.OperationSet = .initEmpty();
    send.insert(.send);
    _ = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "message" },
        .operations = send,
        .constraints = .{ .one_time = true, .recipients = &.{"the venue"} },
    });

    const rows = try projectCapabilities(gpa, &fixture.store, fixture.session(), fixture.now());
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].operations.contains(.send));
    try std.testing.expect(!rows[0].operations.contains(.read));
    try std.testing.expectEqual(@as(?u32, 1), rows[0].remaining_uses);
    try std.testing.expectEqualStrings("Active", rows[0].status_text);
    try std.testing.expect(!rows[0].delegable);
}

test "a spent one-time grant reads as used up rather than active" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var send: capability_model.OperationSet = .initEmpty();
    send.insert(.send);
    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "message" },
        .operations = send,
        .constraints = .{ .one_time = true, .recipients = &.{"the venue"} },
    });

    _ = try fixture.store.use(handle, .{
        .holder = fixture.agent,
        .operation = .send,
        .resource = .{ .kind = "message" },
        .recipient = "the venue",
    });

    const rows = try projectCapabilities(gpa, &fixture.store, fixture.session(), fixture.now());
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(?u32, 0), rows[0].remaining_uses);
    try std.testing.expectEqualStrings("Used up", rows[0].status_text);
}

test "an expired grant reads as expired without being revoked" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var operations: capability_model.OperationSet = .initEmpty();
    operations.insert(.read);
    _ = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = operations,
        .constraints = .{ .expires_at = .fromSeconds(1_500) },
    });

    fixture.manual.advance(.fromSeconds(1_000));

    const rows = try projectCapabilities(gpa, &fixture.store, fixture.session(), fixture.now());
    defer gpa.free(rows);

    try std.testing.expectEqualStrings("Expired", rows[0].status_text);
    try std.testing.expect(!rows[0].revoked);
}

test "a delegated grant shows its distance from the original" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var operations: capability_model.OperationSet = .initEmpty();
    operations.insert(.read);
    const parent = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = operations,
        .constraints = .{ .delegation_depth = 1 },
    });
    _ = try fixture.store.delegate(
        parent,
        fixture.human,
        operations,
        .{ .kind = "calendar" },
        .{},
    );

    const rows = try projectCapabilities(gpa, &fixture.store, fixture.session(), fixture.now());
    defer gpa.free(rows);

    var found_delegated = false;
    for (rows) |row| {
        if (row.depth == 1) {
            found_delegated = true;
            try std.testing.expect(!row.delegable);
        }
    }
    try std.testing.expect(found_delegated);
}

test "resource rows report utilization against the live budget" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var budget: resource.Budget = .init(gpa, 4096, .{
        .principal = fixture.agent,
        .task = .{ .value = 7 },
    });
    const block = try budget.allocator().alloc(u8, 1024);
    defer budget.allocator().free(block);

    const rows = try projectResources(gpa, &.{budget}, fixture.session());
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 1024), rows[0].current_bytes);
    try std.testing.expectEqual(@as(usize, 4096), rows[0].limit_bytes);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), rows[0].utilization, 0.001);
    try std.testing.expectEqualStrings("Within its budget", rows[0].status_text);
}

test "a principal held back by its budget is visible as such" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var budget: resource.Budget = .init(gpa, 512, .{
        .principal = fixture.agent,
        .task = .{ .value = 7 },
    });
    try std.testing.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 4096));

    const rows = try projectResources(gpa, &.{budget}, fixture.session());
    defer gpa.free(rows);

    try std.testing.expect(rows[0].refusals > 0);
    try std.testing.expectEqualStrings("Held back by its budget", rows[0].status_text);
    try std.testing.expectEqual(tokens.ColourRole.status_denied, rows[0].status_colour);
}

test "a budget with no ceiling reports no utilization rather than dividing by zero" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const budget: resource.Budget = .init(gpa, 0, .unattributed);
    const rows = try projectResources(gpa, &.{budget}, fixture.session());
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(f32, 0), rows[0].utilization);
}

test "no inspector is projected before a human authenticates" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const locked: Session = .{ .authenticated = false, .human = .none };

    try std.testing.expectError(error.NotAuthenticated, projectPrincipals(
        gpa,
        &fixture.registry,
        &fixture.store,
        locked,
        fixture.now(),
    ));
    try std.testing.expectError(
        error.NotAuthenticated,
        projectCapabilities(gpa, &fixture.store, locked, fixture.now()),
    );
    try std.testing.expectError(
        error.NotAuthenticated,
        projectResources(gpa, &.{}, locked),
    );
}

test "the principal inspector satisfies the accessibility contract" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const rows = try projectPrincipals(
        gpa,
        &fixture.registry,
        &fixture.store,
        fixture.session(),
        fixture.now(),
    );
    defer gpa.free(rows);

    var surface = try describePrincipals(gpa, rows);
    defer gpa.free(surface.elements);
    defer gpa.free(surface.focus_order);

    try surface.validate(gpa);
    try std.testing.expectEqual(rows.len, surface.focus_order.len);
}

test "a display name is never treated as identity" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A second agent sharing a display name must remain a distinct row with its
    // own identifier and its own authority.
    _ = try fixture.registry.enroll(.{
        .kind = .agent,
        .display_name = "calendar",
        .policy_domain = "local",
        .expires_at = .fromSeconds(5_000),
        .issuer = fixture.human,
    });

    const rows = try projectPrincipals(
        gpa,
        &fixture.registry,
        &fixture.store,
        fixture.session(),
        fixture.now(),
    );
    defer gpa.free(rows);

    var named_calendar: usize = 0;
    for (rows) |row| {
        if (std.mem.eql(u8, row.display_name, "calendar")) named_calendar += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), named_calendar);
    try std.testing.expect(!rows[0].id.eql(rows[1].id));
}
