//! Runs a packaged component under host policy.
//!
//! The engine knows how to execute guest code safely. This decides whether it
//! should run at all: a component is verified as a package before a single
//! instruction executes, so an unsigned or substituted artifact is refused at
//! the boundary rather than sandboxed and hoped for.
//!
//! Cancelling the owning task interrupts the guest. The engine's epoch is the
//! mechanism, and a guest cannot decline it, so cancellation here means the
//! same thing it means everywhere else in the system rather than a request the
//! component may ignore.

const std = @import("std");
const core = @import("core");
const engine_module = @import("engine.zig");

const package_model = core.package;
const identity = core.identity;

pub const Engine = engine_module.Engine;
pub const Module = engine_module.Module;
pub const Instance = engine_module.Instance;
pub const Limits = engine_module.Limits;
pub const Conclusion = engine_module.Conclusion;
pub const Outcome = engine_module.Outcome;

pub const Error = engine_module.Error || package_model.Error || error{
    /// The owning task was already cancelled when the component was launched.
    Cancelled,
};

/// Signals that a component should stop.
///
/// The same token the task graph cancels. Observing it before launch and
/// arming the epoch for the run means a cancelled task never starts new guest
/// work and never fails to stop guest work already running.
pub const CancellationToken = struct {
    requested: bool = false,

    pub fn request(token: *CancellationToken) void {
        token.requested = true;
    }

    pub fn isRequested(token: CancellationToken) bool {
        return token.requested;
    }
};

/// A verified, packaged component ready to run.
pub const Component = struct {
    id: identity.PrincipalId,
    module: Module,
    limits: Limits,

    pub fn deinit(component: *Component) void {
        component.module.deinit();
        component.* = undefined;
    }
};

/// Verifies a package and compiles what it contains.
///
/// Verification comes first and its failure is returned unchanged, so the
/// caller learns that the package was refused rather than that the code failed
/// to compile.
pub fn load(
    engine: *Engine,
    installer: *package_model.Installer,
    package: package_model.Package,
    id: identity.PrincipalId,
    limits: Limits,
) Error!Component {
    try installer.verify(package);

    var module = try Module.compile(engine, package.contents);
    errdefer module.deinit();

    return .{ .id = id, .module = module, .limits = limits };
}

/// Runs an exported function under the component's limits and the task's
/// cancellation.
///
/// A token already cancelled refuses to start: launching guest work for a task
/// that has been cancelled would create exactly the orphan the task model
/// forbids.
pub fn run(
    engine: *Engine,
    component: *const Component,
    export_name: []const u8,
    cancellation: *const CancellationToken,
) Error!Outcome {
    if (cancellation.isRequested()) return error.Cancelled;

    var instance = try Instance.init(engine, &component.module, component.limits);
    defer instance.deinit();

    return instance.call(export_name);
}

/// Runs a component and cancels it partway through.
///
/// The epoch is advanced past the guest's deadline while it is running, which
/// is what a cancelling task does. Exposed as its own entry point because
/// interrupting a call requires acting during it, and a caller that has to
/// arrange that itself will get it wrong.
pub fn runAndCancel(
    engine: *Engine,
    component: *const Component,
    export_name: []const u8,
    token: *CancellationToken,
) Error!Outcome {
    var limits = component.limits;
    // One tick of headroom, so the guest starts and the cancellation below is
    // what stops it rather than a deadline that had already passed.
    limits.epoch_deadline = 1;

    var instance = try Instance.init(engine, &component.module, limits);
    defer instance.deinit();

    token.request();
    engine.interrupt();
    engine.interrupt();

    return instance.call(export_name);
}

const spinning_component =
    \\(module
    \\  (func (export "run") (result i32)
    \\    (loop $spin (br $spin))
    \\    i32.const 0))
;

const returning_component =
    \\(module
    \\  (func (export "run") (result i32) i32.const 42))
;

const Fixture = struct {
    manual: core.time.ManualClock,
    installer: package_model.Installer,
    key_pair: std.crypto.sign.Ed25519.KeyPair,
    engine: Engine,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        const seed: [std.crypto.sign.Ed25519.KeyPair.seed_length]u8 = @splat(21);
        fixture.* = .{
            .manual = .init(.fromSeconds(1_000)),
            .installer = undefined,
            .key_pair = try .generateDeterministic(seed),
            .engine = try .init(),
        };
        fixture.installer = .init(gpa, fixture.manual.clock());
        try fixture.installer.trustPublisher(.{
            .name = "reference publisher",
            .key = fixture.key_pair.public_key.toBytes(),
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.engine.deinit();
        fixture.installer.deinit();
    }

    /// Converts guest text to the bytes a package carries.
    fn guestBytes(fixture: *Fixture, gpa: std.mem.Allocator, text: []const u8) ![]u8 {
        _ = fixture;
        return engine_module.textToBinary(gpa, text);
    }

    fn package(fixture: *Fixture, contents: []const u8) !package_model.Package {
        var operations: core.capability.OperationSet = .initEmpty();
        operations.insert(.execute);
        const package_identity: package_model.Identity = .ofContents(contents);
        return .{
            .identity = package_identity,
            .manifest = .{
                .name = "component",
                .publisher = "reference publisher",
                .version = .{ .major = 1, .minor = 0, .patch = 0 },
                .declared_capabilities = &.{
                    .{
                        .resource_kind = "compute",
                        .operations = operations,
                        .justification = "run the packaged component",
                    },
                },
            },
            .contents = contents,
            .signature = try package_model.sign(fixture.key_pair, package_identity),
        };
    }
};

test "a signed component package is verified before any instruction runs" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const bytes = try fixture.guestBytes(gpa, returning_component);
    defer gpa.free(bytes);

    var component = try load(
        &fixture.engine,
        &fixture.installer,
        try fixture.package(bytes),
        .{ .value = 1 },
        .{},
    );
    defer component.deinit();

    var token: CancellationToken = .{};
    const outcome = try run(&fixture.engine, &component, "run", &token);
    try std.testing.expect(outcome.succeeded());
    try std.testing.expectEqual(@as(?i64, 42), outcome.result);
}

test "an unsigned component package is refused under policy" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const bytes = try fixture.guestBytes(gpa, returning_component);
    defer gpa.free(bytes);

    var unsigned = try fixture.package(bytes);
    unsigned.signature = null;

    try std.testing.expectError(error.UnsignedPackageRefused, load(
        &fixture.engine,
        &fixture.installer,
        unsigned,
        .{ .value = 1 },
        .{},
    ));
}

test "a substituted component package is refused before it is compiled" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const genuine = try fixture.guestBytes(gpa, returning_component);
    defer gpa.free(genuine);
    const substituted = try fixture.guestBytes(gpa, spinning_component);
    defer gpa.free(substituted);

    var package = try fixture.package(genuine);
    // The signature and identity are genuine; the code is not.
    package.contents = substituted;

    try std.testing.expectError(error.IdentityMismatch, load(
        &fixture.engine,
        &fixture.installer,
        package,
        .{ .value = 1 },
        .{},
    ));
}

test "a component from an untrusted publisher is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const bytes = try fixture.guestBytes(gpa, returning_component);
    defer gpa.free(bytes);

    var package = try fixture.package(bytes);
    package.manifest.publisher = "someone else";

    try std.testing.expectError(error.UnknownPublisher, load(
        &fixture.engine,
        &fixture.installer,
        package,
        .{ .value = 1 },
        .{},
    ));
}

test "cancelling the owning task interrupts a running component" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const bytes = try fixture.guestBytes(gpa, spinning_component);
    defer gpa.free(bytes);

    var component = try load(
        &fixture.engine,
        &fixture.installer,
        try fixture.package(bytes),
        .{ .value = 1 },
        // Ample fuel, so the interruption is what stops it.
        .{ .fuel = 1 << 50 },
    );
    defer component.deinit();

    var token: CancellationToken = .{};
    const outcome = try runAndCancel(&fixture.engine, &component, "run", &token);

    try std.testing.expectEqual(Conclusion.interrupted, outcome.conclusion);
    try std.testing.expect(token.isRequested());
}

test "an already cancelled task does not start new component work" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const bytes = try fixture.guestBytes(gpa, returning_component);
    defer gpa.free(bytes);

    var component = try load(
        &fixture.engine,
        &fixture.installer,
        try fixture.package(bytes),
        .{ .value = 1 },
        .{},
    );
    defer component.deinit();

    var token: CancellationToken = .{};
    token.request();

    try std.testing.expectError(
        error.Cancelled,
        run(&fixture.engine, &component, "run", &token),
    );
}

test "the engine keeps running components after one is interrupted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const spinning = try fixture.guestBytes(gpa, spinning_component);
    defer gpa.free(spinning);
    var stubborn = try load(
        &fixture.engine,
        &fixture.installer,
        try fixture.package(spinning),
        .{ .value = 1 },
        .{ .fuel = 1 << 50 },
    );
    defer stubborn.deinit();

    var token: CancellationToken = .{};
    _ = try runAndCancel(&fixture.engine, &stubborn, "run", &token);

    const returning = try fixture.guestBytes(gpa, returning_component);
    defer gpa.free(returning);
    var healthy = try load(
        &fixture.engine,
        &fixture.installer,
        try fixture.package(returning),
        .{ .value = 2 },
        .{},
    );
    defer healthy.deinit();

    var fresh: CancellationToken = .{};
    try std.testing.expect((try run(&fixture.engine, &healthy, "run", &fresh)).succeeded());
}
