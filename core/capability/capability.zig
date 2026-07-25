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
const principal_model = @import("../principal/principal.zig");
const provenance_model = @import("../provenance/provenance.zig");
const outcome = @import("../base/outcome.zig");

const types = @import("types.zig");
const errors = @import("errors.zig");
const store = @import("store.zig");

pub const Operation = types.Operation;
pub const OperationSet = types.OperationSet;
pub const ResourceSelector = types.ResourceSelector;
pub const RevocationBehavior = types.RevocationBehavior;
pub const Constraints = types.Constraints;
pub const RateLimit = types.RateLimit;
pub const UseContext = types.UseContext;
pub const Capability = types.Capability;
pub const Handle = types.Handle;
pub const Grant = types.Grant;
pub const Refusal = errors.Refusal;
pub const Store = store.Store;
const permittedInvocations = store.permittedInvocations;

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

test "a grant that has expired stays expired when the wall clock rolls back" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .expires_at = .fromSeconds(1_100) },
    });
    const context: UseContext = .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    };

    // Move past expiry; the grant is refused and the floor advances.
    fixture.manual.advance(.fromSeconds(300));
    try std.testing.expectError(error.CapabilityExpired, fixture.store.check(handle, context));

    // Roll the wall clock back before the expiry. Without a floor the grant
    // would look valid again; with one it stays expired.
    fixture.manual.skewWall(.fromSeconds(-1_000));
    try std.testing.expectError(error.CapabilityExpired, fixture.store.check(handle, context));
}

test "a model-restricted grant refuses another model and admits the named one" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .model_restrictions = &.{"reviewed-planner"} },
    });

    try std.testing.expectError(error.ConstraintViolation, fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .model = "some-other-model",
    }));
    _ = try fixture.store.check(handle, .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
        .model = "reviewed-planner",
    });
}

test "a rate limit refuses a burst and admits a use in the next window" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .rate_limit = .{ .max_uses = 2, .window = .fromSeconds(60) } },
    });
    const context: UseContext = .{
        .holder = fixture.agent,
        .operation = .read,
        .resource = .{ .kind = "calendar" },
    };

    _ = try fixture.store.use(handle, context);
    _ = try fixture.store.use(handle, context);
    // A third use inside the window is refused.
    try std.testing.expectError(error.BudgetExhausted, fixture.store.use(handle, context));

    // Once the window elapses, uses are admitted again.
    fixture.manual.advance(.fromSeconds(61));
    _ = try fixture.store.use(handle, context);
}

test "issue and delegate leak nothing when an allocation fails" {
    // Setup registers its cleanup before each fallible step, so a failure at any
    // allocation — in enrolment, issue, or delegate — still releases everything.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var ids: identity.Source = .initDeterministic(20260722);
            var manual: time.ManualClock = .init(.fromSeconds(1_000));
            var registry: principal_model.Registry = .init(gpa, &ids, manual.clock());
            defer registry.deinit();
            var cap_store: Store = .init(gpa, &ids, manual.clock(), &registry);
            defer cap_store.deinit();

            const human = try registry.enroll(.{ .kind = .human, .display_name = "operator", .policy_domain = "local" });
            const agent = try registry.enroll(.{ .kind = .agent, .display_name = "calendar", .policy_domain = "local", .expires_at = .fromSeconds(100_000), .issuer = human });
            const other = try registry.enroll(.{ .kind = .agent, .display_name = "travel", .policy_domain = "local", .expires_at = .fromSeconds(100_000), .issuer = human });

            var read: OperationSet = .initEmpty();
            read.insert(.read);

            const parent = try cap_store.issue(.{
                .issuer = human,
                .holder = agent,
                .resource = .{ .kind = "calendar" },
                .operations = read,
                .constraints = .{ .delegation_depth = 1 },
            });
            _ = try cap_store.delegate(parent, other, read, .{ .kind = "calendar" }, .{});
        }
    }.run, .{});
}

test "a grant does not cross policy domains without explicit permission" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A holder in a different domain from the issuer.
    const offshore = try fixture.registry.enroll(.{
        .kind = .agent,
        .display_name = "offshore",
        .policy_domain = "work",
        .expires_at = .fromSeconds(100_000),
        .issuer = fixture.human,
    });

    // The human is in "local"; issuing to a "work" holder crosses a domain.
    try std.testing.expectError(error.Unauthorized, fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = offshore,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
    }));

    // With the crossing made explicit, the same grant is allowed.
    _ = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = offshore,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .permit_cross_domain = true },
    });
}

test "a capability request from unvalidated model output is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A request whose intent came straight from a model, cleared for nothing.
    try std.testing.expectError(error.Unauthorized, fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .provenance = .from(.model_output),
    }));

    // Once validated for a capability request, the same origin may be issued.
    const validated = provenance_model.validate(.from(.model_output), .capability_request, true).?.result;
    _ = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .provenance = validated,
    });
}

test "revoking a grant revokes the whole delegation subtree, not only its children" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A third agent to hold the grandchild grant.
    const third_agent = try fixture.registry.enroll(.{
        .kind = .agent,
        .display_name = "documents",
        .policy_domain = "local",
        .expires_at = .fromSeconds(100_000),
        .issuer = fixture.human,
    });

    // A three-deep chain: human → agent → other_agent → third_agent.
    const parent = try fixture.store.issue(.{
        .issuer = fixture.human,
        .holder = fixture.agent,
        .resource = .{ .kind = "calendar" },
        .operations = fixture.readOnly(),
        .constraints = .{ .delegation_depth = 2 },
    });
    const child = try fixture.store.delegate(parent, fixture.other_agent, fixture.readOnly(), .{ .kind = "calendar" }, .{ .delegation_depth = 1 });
    const grandchild = try fixture.store.delegate(child, third_agent, fixture.readOnly(), .{ .kind = "calendar" }, .{});

    // The grandchild works before revocation.
    _ = try fixture.store.check(grandchild, .{ .holder = third_agent, .operation = .read, .resource = .{ .kind = "calendar" } });

    // Revoking the root withdraws every grant derived from it, at any depth.
    try fixture.store.revoke(parent.id);

    try std.testing.expect(fixture.store.lookup(child.id).?.revoked);
    try std.testing.expect(fixture.store.lookup(grandchild.id).?.revoked);
    try std.testing.expectError(error.IntegrityFailure, fixture.store.check(grandchild, .{
        .holder = third_agent,
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
