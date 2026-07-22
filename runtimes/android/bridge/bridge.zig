//! The Android application boundary.
//!
//! An Android application is a principal of its own, enrolled by the host and
//! holding whatever the host granted it. Its identity inside the Android
//! framework — its package name, its user identifier, whatever the framework
//! believes about it — is separate and is never used to authorize anything
//! here.
//!
//! Keeping the two apart is what makes the boundary a boundary. If a package
//! name resolved to host authority, an application could obtain authority by
//! being installed under the right name, and installation is not a decision
//! about authority.
//!
//! The bridge also exposes application capabilities to the host: an application
//! can offer a typed operation that an agent may invoke without navigating its
//! screens. What it offers is a declaration; whether anyone may invoke it is a
//! separate decision.

const std = @import("std");
const core = @import("core");
const permission_model = @import("../permissions/permissions.zig");

const identity = core.identity;
const capability_model = core.capability;
const outcome_model = core.outcome;

pub const Error = error{
    /// The application is not installed here.
    UnknownApplication,
    /// The application is installed but not running.
    NotRunning,
    /// The application does not offer that operation.
    OperationNotOffered,
    /// The caller holds no capability for the operation.
    Unauthorized,
    /// The application declares a dependency this host cannot satisfy.
    UnsatisfiableDependency,
    /// The Android runtime is not available.
    RuntimeUnavailable,
    /// The application failed while handling the call.
    ApplicationFault,
};

pub const max_package_name_bytes: usize = 255;
pub const max_operation_name_bytes: usize = 64;

/// What the Android framework believes about an application.
///
/// Held separately from the host principal and never consulted when deciding
/// whether something may act.
pub const FrameworkIdentity = struct {
    package_name: []const u8,
    /// The framework's own user identifier for the application.
    framework_user_id: u32,

    pub fn validate(framework: FrameworkIdentity) Error!void {
        if (framework.package_name.len == 0) return error.UnknownApplication;
        if (framework.package_name.len > max_package_name_bytes) return error.UnknownApplication;
    }
};

/// A typed operation an application offers to the host.
pub const OfferedOperation = struct {
    name: []const u8,
    /// The host resource kind this operation acts on.
    resource_kind: []const u8,
    /// What invoking it does, in host terms.
    operation: capability_model.Operation,
    /// A bounded description shown when a human is asked to authorize it.
    summary: []const u8,
};

/// An installed Android application.
pub const Application = struct {
    /// The host principal. This is what authorization uses.
    principal: identity.PrincipalId,
    /// What the framework believes. Never used to authorize.
    framework: FrameworkIdentity,
    /// Human-readable label. Metadata, like any display name.
    label: []const u8,
    /// Capability requests derived from the application's manifest.
    requests: []const permission_model.Request,
    /// Operations the application offers to the host.
    offers: []const OfferedOperation,
    /// Service dependencies this host cannot satisfy.
    unsatisfiable_dependencies: []const []const u8,
    running: bool = false,

    /// Whether this application can be launched honestly.
    ///
    /// An application depending on a service this host does not provide will
    /// fail in ways a person cannot explain, so it is reported as unrunnable
    /// rather than started and left to break.
    pub fn isLaunchable(application: Application) bool {
        return application.unsatisfiable_dependencies.len == 0;
    }
};

/// The result of invoking an application capability.
pub const Invocation = struct {
    outcome: outcome_model.Outcome,
    /// Set when the invocation was refused or failed.
    refusal: ?outcome_model.DomainError,
};

/// Mediates between the host and installed Android applications.
///
/// Ownership: the bridge owns its application records and the strings it copies
/// from each installation. `deinit` releases them.
pub const Bridge = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    /// Whether the Android runtime is present on this host. When it is not,
    /// every operation reports that plainly rather than failing obscurely.
    runtime_available: bool,
    applications: std.ArrayList(*Application) = .empty,
    /// Invocations refused because the caller held no capability. Non-zero is
    /// worth surfacing: it means something is repeatedly reaching for authority
    /// it does not have.
    unauthorized_invocations: u64 = 0,
    /// Faults inside applications. The bridge continuing to serve other
    /// applications with a non-zero count here is the containment property.
    application_faults: u64 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        ids: *identity.Source,
        runtime_available: bool,
    ) Bridge {
        return .{ .gpa = gpa, .ids = ids, .runtime_available = runtime_available };
    }

    pub fn deinit(bridge: *Bridge) void {
        for (bridge.applications.items) |application| {
            bridge.gpa.free(application.framework.package_name);
            bridge.gpa.free(application.label);
            bridge.gpa.destroy(application);
        }
        bridge.applications.deinit(bridge.gpa);
        bridge.* = undefined;
    }

    /// What an installation supplies.
    pub const Installation = struct {
        framework: FrameworkIdentity,
        label: []const u8,
        requests: []const permission_model.Request,
        offers: []const OfferedOperation,
        unsatisfiable_dependencies: []const []const u8 = &.{},
    };

    /// Installs an application and enrolls it as a host principal.
    ///
    /// The host principal is issued here, not derived from anything the
    /// framework supplies, so two applications claiming the same package name
    /// are still two principals.
    pub fn install(bridge: *Bridge, installation: Installation) !*Application {
        if (!bridge.runtime_available) return error.RuntimeUnavailable;
        try installation.framework.validate();

        for (installation.offers) |offer| {
            if (offer.name.len == 0 or offer.name.len > max_operation_name_bytes) {
                return error.OperationNotOffered;
            }
        }

        const package_name = try bridge.gpa.dupe(u8, installation.framework.package_name);
        errdefer bridge.gpa.free(package_name);
        const label = try bridge.gpa.dupe(u8, installation.label);
        errdefer bridge.gpa.free(label);

        const application = try bridge.gpa.create(Application);
        errdefer bridge.gpa.destroy(application);
        application.* = .{
            .principal = bridge.ids.next(identity.PrincipalId),
            .framework = .{
                .package_name = package_name,
                .framework_user_id = installation.framework.framework_user_id,
            },
            .label = label,
            .requests = installation.requests,
            .offers = installation.offers,
            .unsatisfiable_dependencies = installation.unsatisfiable_dependencies,
        };

        try bridge.applications.append(bridge.gpa, application);
        return application;
    }

    /// Finds an application by its host principal.
    ///
    /// Lookup is by principal, never by package name: resolving authority
    /// through a framework-supplied name is exactly what the boundary exists to
    /// prevent.
    pub fn find(bridge: *Bridge, principal: identity.PrincipalId) ?*Application {
        for (bridge.applications.items) |application| {
            if (application.principal.eql(principal)) return application;
        }
        return null;
    }

    pub fn launch(bridge: *Bridge, application: *Application) Error!void {
        if (!bridge.runtime_available) return error.RuntimeUnavailable;
        if (!application.isLaunchable()) return error.UnsatisfiableDependency;
        application.running = true;
    }

    pub fn stop(bridge: *Bridge, application: *Application) void {
        _ = bridge;
        application.running = false;
    }

    /// Reports that an application faulted.
    ///
    /// The application stops; the bridge and every other application keep
    /// running. A compatibility runtime's failure must not reach the host.
    pub fn reportFault(bridge: *Bridge, application: *Application) void {
        application.running = false;
        bridge.application_faults += 1;
    }

    /// Invokes an operation an application offers.
    ///
    /// The caller must hold a capability covering it. The capability is checked
    /// against the host's store, not against anything the application or the
    /// framework asserts.
    pub fn invoke(
        bridge: *Bridge,
        application: *Application,
        operation_name: []const u8,
        caller: identity.PrincipalId,
        store: *capability_model.Store,
        handle: capability_model.Handle,
        task: identity.TaskId,
    ) Error!Invocation {
        if (!bridge.runtime_available) return error.RuntimeUnavailable;
        if (!application.running) return error.NotRunning;

        const offer = findOffer(application, operation_name) orelse
            return error.OperationNotOffered;

        _ = store.use(handle, .{
            .holder = caller,
            .operation = offer.operation,
            .resource = .{ .kind = offer.resource_kind },
            .task = task,
            .human_confirmed = true,
        }) catch |refusal| {
            bridge.unauthorized_invocations += 1;
            return .{ .outcome = .denied, .refusal = refusal };
        };

        return .{ .outcome = .succeeded, .refusal = null };
    }

    /// Whether the runtime is present, so a surface can say so rather than
    /// presenting an application that cannot start.
    pub fn isRuntimeAvailable(bridge: Bridge) bool {
        return bridge.runtime_available;
    }

    pub fn installedCount(bridge: Bridge) usize {
        return bridge.applications.len();
    }
};

fn findOffer(application: *const Application, name: []const u8) ?OfferedOperation {
    for (application.offers) |offer| {
        if (std.mem.eql(u8, offer.name, name)) return offer;
    }
    return null;
}

const calendar_offers = [_]OfferedOperation{
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

const Fixture = struct {
    ids: identity.Source,
    manual: core.time.ManualClock,
    registry: core.principal.Registry,
    store: capability_model.Store,
    bridge: Bridge,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture, runtime_available: bool) !void {
        fixture.* = .{
            .ids = .initDeterministic(6161),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .bridge = undefined,
            .human = .none,
            .agent = .none,
        };
        const clock = fixture.manual.clock();
        fixture.registry = .init(gpa, &fixture.ids, clock);
        fixture.store = .init(gpa, &fixture.ids, clock, &fixture.registry);
        fixture.bridge = .init(gpa, &fixture.ids, runtime_available);

        fixture.human = try fixture.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
        });
        fixture.agent = try fixture.registry.enroll(.{
            .kind = .agent,
            .display_name = "calendar",
            .policy_domain = "local",
            .expires_at = .fromSeconds(50_000),
            .issuer = fixture.human,
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.bridge.deinit();
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    fn installCalendar(fixture: *Fixture) !*Application {
        return fixture.bridge.install(.{
            .framework = .{ .package_name = "com.example.calendar", .framework_user_id = 10_042 },
            .label = "Calendar",
            .requests = &.{},
            .offers = &calendar_offers,
        });
    }

    fn grant(
        fixture: *Fixture,
        operation: capability_model.Operation,
    ) !capability_model.Handle {
        var operations: capability_model.OperationSet = .initEmpty();
        operations.insert(operation);
        return fixture.store.issue(.{
            .issuer = fixture.human,
            .holder = fixture.agent,
            .resource = .{ .kind = "calendar" },
            .operations = operations,
        });
    }
};

test "an application is enrolled as its own principal, separate from the framework" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const application = try fixture.installCalendar();

    try std.testing.expect(!application.principal.isNone());
    try std.testing.expectEqualStrings("com.example.calendar", application.framework.package_name);
    // The framework's identifier is held but is not the principal.
    try std.testing.expect(application.principal.value != application.framework.framework_user_id);
}

test "two applications claiming the same package name are still two principals" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const first = try fixture.installCalendar();
    const second = try fixture.installCalendar();

    // If a package name resolved to authority, installing under the right name
    // would be a way to obtain it.
    try std.testing.expect(!first.principal.eql(second.principal));
    try std.testing.expectEqualStrings(
        first.framework.package_name,
        second.framework.package_name,
    );
}

test "an application capability is invoked only with a host capability" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const application = try fixture.installCalendar();
    try fixture.bridge.launch(application);

    const handle = try fixture.grant(.read);
    const invocation = try fixture.bridge.invoke(
        application,
        "read_next_event",
        fixture.agent,
        &fixture.store,
        handle,
        .{ .value = 5 },
    );

    try std.testing.expectEqual(outcome_model.Outcome.succeeded, invocation.outcome);
}

test "an unauthorized host capability request is denied" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const application = try fixture.installCalendar();
    try fixture.bridge.launch(application);

    // A read grant does not authorize creating an event.
    const read_only = try fixture.grant(.read);
    const invocation = try fixture.bridge.invoke(
        application,
        "create_event",
        fixture.agent,
        &fixture.store,
        read_only,
        .{ .value = 5 },
    );

    try std.testing.expectEqual(outcome_model.Outcome.denied, invocation.outcome);
    try std.testing.expectEqual(outcome_model.DomainError.Unauthorized, invocation.refusal.?);
    try std.testing.expectEqual(@as(u64, 1), fixture.bridge.unauthorized_invocations);
}

test "an operation the application does not offer cannot be invoked" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const application = try fixture.installCalendar();
    try fixture.bridge.launch(application);
    const handle = try fixture.grant(.read);

    try std.testing.expectError(error.OperationNotOffered, fixture.bridge.invoke(
        application,
        "delete_everything",
        fixture.agent,
        &fixture.store,
        handle,
        .{ .value = 5 },
    ));
}

test "an application that is not running cannot be invoked" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const application = try fixture.installCalendar();
    const handle = try fixture.grant(.read);

    try std.testing.expectError(error.NotRunning, fixture.bridge.invoke(
        application,
        "read_next_event",
        fixture.agent,
        &fixture.store,
        handle,
        .{ .value = 5 },
    ));
}

test "an application fault stops that application and nothing else" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const faulting = try fixture.installCalendar();
    const healthy = try fixture.bridge.install(.{
        .framework = .{ .package_name = "com.example.notes", .framework_user_id = 10_043 },
        .label = "Notes",
        .requests = &.{},
        .offers = &calendar_offers,
    });

    try fixture.bridge.launch(faulting);
    try fixture.bridge.launch(healthy);

    fixture.bridge.reportFault(faulting);

    try std.testing.expect(!faulting.running);
    try std.testing.expect(healthy.running);
    try std.testing.expectEqual(@as(u64, 1), fixture.bridge.application_faults);

    // The bridge keeps serving the application that did not fault.
    const handle = try fixture.grant(.read);
    const invocation = try fixture.bridge.invoke(
        healthy,
        "read_next_event",
        fixture.agent,
        &fixture.store,
        handle,
        .{ .value = 5 },
    );
    try std.testing.expectEqual(outcome_model.Outcome.succeeded, invocation.outcome);
}

test "an application with an unsatisfiable dependency is not launched" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const application = try fixture.bridge.install(.{
        .framework = .{ .package_name = "com.example.maps", .framework_user_id = 10_044 },
        .label = "Maps",
        .requests = &.{},
        .offers = &.{},
        .unsatisfiable_dependencies = &.{"com.google.android.gms"},
    });

    try std.testing.expect(!application.isLaunchable());
    try std.testing.expectError(
        error.UnsatisfiableDependency,
        fixture.bridge.launch(application),
    );
    try std.testing.expect(!application.running);
}

test "the runtime being absent is reported plainly rather than failing obscurely" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, false);
    defer fixture.deinit();

    try std.testing.expect(!fixture.bridge.isRuntimeAvailable());
    try std.testing.expectError(error.RuntimeUnavailable, fixture.installCalendar());
}

test "lookup is by host principal, never by package name" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const first = try fixture.installCalendar();
    const second = try fixture.installCalendar();

    try std.testing.expectEqual(first, fixture.bridge.find(first.principal).?);
    try std.testing.expectEqual(second, fixture.bridge.find(second.principal).?);
    try std.testing.expectEqual(
        @as(?*Application, null),
        fixture.bridge.find(.{ .value = 0xdead }),
    );

    // The bridge exposes no way to resolve an application by what the framework
    // calls it, which is what stops a name becoming authority.
    inline for (@typeInfo(Bridge).@"struct".decls) |declaration| {
        try std.testing.expect(!std.mem.eql(u8, declaration.name, "findByPackageName"));
    }
}

test "an offered operation must be named and bounded" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const unnamed = [_]OfferedOperation{
        .{ .name = "", .resource_kind = "calendar", .operation = .read, .summary = "unnamed" },
    };
    try std.testing.expectError(error.OperationNotOffered, fixture.bridge.install(.{
        .framework = .{ .package_name = "com.example.broken", .framework_user_id = 1 },
        .label = "Broken",
        .requests = &.{},
        .offers = &unnamed,
    }));
}

test "a package name that is empty or unbounded is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    try std.testing.expectError(error.UnknownApplication, fixture.bridge.install(.{
        .framework = .{ .package_name = "", .framework_user_id = 1 },
        .label = "Nameless",
        .requests = &.{},
        .offers = &.{},
    }));

    const overlong: [max_package_name_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.UnknownApplication, fixture.bridge.install(.{
        .framework = .{ .package_name = &overlong, .framework_user_id = 1 },
        .label = "Overlong",
        .requests = &.{},
        .offers = &.{},
    }));
}

test "a revoked capability stops further invocations immediately" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture, true);
    defer fixture.deinit();

    const application = try fixture.installCalendar();
    try fixture.bridge.launch(application);

    const handle = try fixture.grant(.read);
    _ = try fixture.bridge.invoke(
        application,
        "read_next_event",
        fixture.agent,
        &fixture.store,
        handle,
        .{ .value = 5 },
    );

    try fixture.store.revoke(handle.id);

    const after = try fixture.bridge.invoke(
        application,
        "read_next_event",
        fixture.agent,
        &fixture.store,
        handle,
        .{ .value = 5 },
    );
    try std.testing.expectEqual(outcome_model.Outcome.denied, after.outcome);
}
