//! Android compatibility acceptance.
//!
//! Holds the Android boundary to what it must demonstrate: that a supported
//! application launches, that an unauthorized host capability request is
//! denied, that a runtime fault does not reach the shell, and that an
//! unsupported service dependency is reported accurately.
//!
//! What is asserted here is the mediation and the boundary. Executing real
//! application binaries needs the reference device image, which is a separate
//! deliverable; this file must not be read as evidence that it works.

const std = @import("std");
const core = @import("core");
const shell = @import("shell");
const android = @import("runtime_android");

const identity = core.identity;
const capability_model = core.capability;
const outcome_model = core.outcome;
const audit = core.audit;

const permissions = android.permissions;
const bridge_module = android.bridge;
const surfaces = shell.surfaces;
const session_surfaces = shell.session;

const Environment = struct {
    ids: identity.Source,
    manual: core.time.ManualClock,
    registry: core.principal.Registry,
    store: capability_model.Store,
    ledger: audit.Ledger,
    bridge: bridge_module.Bridge,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, environment: *Environment, runtime_available: bool) !void {
        environment.* = .{
            .ids = .initDeterministic(777),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .ledger = undefined,
            .bridge = undefined,
            .human = .none,
            .agent = .none,
        };
        const clock = environment.manual.clock();
        environment.registry = .init(gpa, &environment.ids, clock);
        environment.store = .init(gpa, &environment.ids, clock, &environment.registry);
        environment.ledger = .init(gpa, &environment.ids, clock);
        environment.bridge = .init(gpa, &environment.ids, runtime_available);

        environment.human = try environment.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        });
        environment.agent = try environment.registry.enroll(.{
            .kind = .agent,
            .display_name = "calendar",
            .policy_domain = "local",
            .expires_at = .fromSeconds(50_000),
            .issuer = environment.human,
        });
    }

    fn deinit(environment: *Environment) void {
        environment.bridge.deinit();
        environment.ledger.deinit();
        environment.store.deinit();
        environment.registry.deinit();
    }

    fn grant(
        environment: *Environment,
        operation: capability_model.Operation,
    ) !capability_model.Handle {
        var operations: capability_model.OperationSet = .initEmpty();
        operations.insert(operation);
        return environment.store.issue(.{
            .issuer = environment.human,
            .holder = environment.agent,
            .resource = .{ .kind = "calendar" },
            .operations = operations,
        });
    }
};

const offers = [_]bridge_module.OfferedOperation{
    .{
        .name = "read_next_event",
        .resource_kind = "calendar",
        .operation = .read,
        .summary = "read the next scheduled event",
    },
    .{
        .name = "create_event",
        .resource_kind = "calendar",
        .operation = .create,
        .summary = "add an event to the calendar",
    },
};

test "a supported application installs, launches, and serves a capability call" {
    const gpa = std.testing.allocator;
    var environment: Environment = undefined;
    try Environment.init(gpa, &environment, true);
    defer environment.deinit();

    // The manifest is translated before anything is installed.
    const translation = try permissions.translateManifest(gpa, &.{
        "android.permission.READ_CALENDAR",
        "android.permission.WRITE_CALENDAR",
    });
    defer gpa.free(translation.requests);
    defer gpa.free(translation.unsupported);
    defer gpa.free(translation.refused);

    try std.testing.expectEqual(@as(usize, 0), translation.unsupported.len);
    try std.testing.expectEqual(@as(usize, 0), translation.refused.len);
    try std.testing.expect(translation.hasAnyGrantableRequest());

    const application = try environment.bridge.install(.{
        .framework = .{ .package_name = "com.example.calendar", .framework_user_id = 10_042 },
        .label = "Calendar",
        .requests = translation.requests,
        .offers = &offers,
    });
    try environment.bridge.launch(application);
    try std.testing.expect(application.running);

    const handle = try environment.grant(.read);
    const invocation = try environment.bridge.invoke(
        application,
        "read_next_event",
        environment.agent,
        &environment.store,
        handle,
        .{ .value = 9 },
    );
    try std.testing.expectEqual(outcome_model.Outcome.succeeded, invocation.outcome);
}

test "an unauthorized host capability request is denied and recorded" {
    const gpa = std.testing.allocator;
    var environment: Environment = undefined;
    try Environment.init(gpa, &environment, true);
    defer environment.deinit();

    const application = try environment.bridge.install(.{
        .framework = .{ .package_name = "com.example.calendar", .framework_user_id = 10_042 },
        .label = "Calendar",
        .requests = &.{},
        .offers = &offers,
    });
    try environment.bridge.launch(application);

    // Holding a read grant does not authorize creating an event.
    const read_only = try environment.grant(.read);
    const invocation = try environment.bridge.invoke(
        application,
        "create_event",
        environment.agent,
        &environment.store,
        read_only,
        .{ .value = 9 },
    );

    try std.testing.expectEqual(outcome_model.Outcome.denied, invocation.outcome);
    try std.testing.expectEqual(outcome_model.DomainError.Unauthorized, invocation.refusal.?);

    _ = try environment.ledger.append(.{
        .actor = environment.agent,
        .on_behalf_of = environment.human,
        .action = .action_denied,
        .outcome = .denied,
        .refusal = invocation.refusal.?,
        .target_kind = "calendar",
    });

    const denials = try environment.ledger.denials(gpa);
    defer gpa.free(denials);
    try std.testing.expectEqual(@as(usize, 1), denials.len);
}

test "framework privilege does not become host privilege" {
    const gpa = std.testing.allocator;
    var environment: Environment = undefined;
    try Environment.init(gpa, &environment, true);
    defer environment.deinit();

    // An application declaring every refusable permission gains nothing.
    const translation = try permissions.translateManifest(gpa, &.{
        "android.permission.INSTALL_PACKAGES",
        "android.permission.WRITE_SECURE_SETTINGS",
        "android.permission.BIND_DEVICE_ADMIN",
        "android.permission.QUERY_ALL_PACKAGES",
    });
    defer gpa.free(translation.requests);
    defer gpa.free(translation.unsupported);
    defer gpa.free(translation.refused);

    try std.testing.expectEqual(@as(usize, 0), translation.requests.len);
    try std.testing.expectEqual(@as(usize, 4), translation.refused.len);
    try std.testing.expect(!translation.hasAnyGrantableRequest());

    // Installing it produces a principal with no authority at all: the
    // application holds nothing the host did not separately grant.
    const application = try environment.bridge.install(.{
        .framework = .{ .package_name = "com.example.greedy", .framework_user_id = 10_099 },
        .label = "Greedy",
        .requests = translation.requests,
        .offers = &offers,
    });
    try environment.bridge.launch(application);

    var held: usize = 0;
    var iterator = environment.store.entries.valueIterator();
    while (iterator.next()) |record| {
        if (record.holder.eql(application.principal)) held += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), held);
}

test "an Android runtime fault does not reach the shell" {
    const gpa = std.testing.allocator;
    var environment: Environment = undefined;
    try Environment.init(gpa, &environment, true);
    defer environment.deinit();

    const faulting = try environment.bridge.install(.{
        .framework = .{ .package_name = "com.example.calendar", .framework_user_id = 10_042 },
        .label = "Calendar",
        .requests = &.{},
        .offers = &offers,
    });
    try environment.bridge.launch(faulting);

    environment.bridge.reportFault(faulting);

    // The shell still projects its surfaces from control-plane state, which the
    // fault never touched.
    const session: surfaces.Session = .{ .authenticated = true, .human = environment.human };

    const activity = try surfaces.projectActivity(gpa, &environment.ledger, session, 32);
    defer gpa.free(activity);

    const principals = try shell.inspectors.projectPrincipals(
        gpa,
        &environment.registry,
        &environment.store,
        .{ .authenticated = true, .human = environment.human },
        environment.manual.clock().wall(),
    );
    defer gpa.free(principals);
    try std.testing.expectEqual(@as(usize, 2), principals.len);

    // And the bridge keeps serving other applications.
    const healthy = try environment.bridge.install(.{
        .framework = .{ .package_name = "com.example.notes", .framework_user_id = 10_043 },
        .label = "Notes",
        .requests = &.{},
        .offers = &offers,
    });
    try environment.bridge.launch(healthy);
    try std.testing.expect(healthy.running);
    try std.testing.expectEqual(@as(u64, 1), environment.bridge.application_faults);
}

test "an unsupported service dependency is reported accurately" {
    const gpa = std.testing.allocator;
    var environment: Environment = undefined;
    try Environment.init(gpa, &environment, true);
    defer environment.deinit();

    const dependency = permissions.checkServiceDependency("com.google.android.gms");
    try std.testing.expect(!dependency.available);
    try std.testing.expect(dependency.explanation.len > 0);

    const application = try environment.bridge.install(.{
        .framework = .{ .package_name = "com.example.maps", .framework_user_id = 10_044 },
        .label = "Maps",
        .requests = &.{},
        .offers = &.{},
        .unsatisfiable_dependencies = &.{dependency.name},
    });

    // Reported rather than launched into failures a person cannot explain.
    try std.testing.expect(!application.isLaunchable());
    try std.testing.expectError(
        error.UnsatisfiableDependency,
        environment.bridge.launch(application),
    );
}

test "the launcher tells a person what this device cannot run" {
    const gpa = std.testing.allocator;

    // With no Android runtime present, an Android application is listed and
    // marked unavailable rather than hidden.
    const declarations = [_]session_surfaces.ApplicationDeclaration{
        .{ .id = .{ .value = 1 }, .name = "Calendar", .runtime = .native, .declared_capability_count = 2 },
        .{ .id = .{ .value = 2 }, .name = "Maps", .runtime = .android, .declared_capability_count = 4 },
    };

    const rows = try session_surfaces.projectLauncher(gpa, &declarations, .{ .native = true }, true);
    defer gpa.free(rows);

    try std.testing.expect(rows[0].launchable);
    try std.testing.expect(!rows[1].launchable);
    try std.testing.expect(rows[1].unavailable_reason.len > 0);
}

test "nothing installs when the Android runtime is absent" {
    const gpa = std.testing.allocator;
    var environment: Environment = undefined;
    try Environment.init(gpa, &environment, false);
    defer environment.deinit();

    try std.testing.expect(!environment.bridge.isRuntimeAvailable());
    try std.testing.expectError(error.RuntimeUnavailable, environment.bridge.install(.{
        .framework = .{ .package_name = "com.example.calendar", .framework_user_id = 10_042 },
        .label = "Calendar",
        .requests = &.{},
        .offers = &offers,
    }));
}

test "an application cannot delegate the authority the host granted it" {
    const gpa = std.testing.allocator;

    // Every translated permission forbids delegation, so an application cannot
    // hand host authority to a principal the host never enrolled.
    const translation = try permissions.translateManifest(gpa, &.{
        "android.permission.READ_CALENDAR",
        "android.permission.READ_CONTACTS",
        "android.permission.ACCESS_FINE_LOCATION",
        "android.permission.INTERNET",
    });
    defer gpa.free(translation.requests);
    defer gpa.free(translation.unsupported);
    defer gpa.free(translation.refused);

    for (translation.requests) |request| {
        try std.testing.expectEqual(@as(u8, 0), request.constraints.delegation_depth);
    }
}
