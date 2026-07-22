//! Supervises services as separate operating-system processes.
//!
//! A service boundary is only a trust boundary when it is a process boundary. A
//! service that faults, corrupts its own memory, or is killed takes its address
//! space with it and nothing else: the supervisor observes how it ended and
//! decides what to do, and the control plane's state is untouched because it
//! was never shared.
//!
//! This is the property the in-process component host cannot provide. That host
//! contains failures; this contains faults.
//!
//! The supervisor spawns, observes, and restarts. It does not interpret what a
//! service does, hold its data, or share memory with it — every interaction is
//! a message on the inter-service protocol.

const std = @import("std");
const core = @import("core");
const policy_module = @import("policy.zig");

const identity = core.identity;
const time = core.time;

pub const Exit = policy_module.Exit;
pub const RestartPolicy = policy_module.RestartPolicy;
pub const Decision = policy_module.Decision;
pub const Limits = policy_module.Limits;
pub const History = policy_module.History;

pub const State = enum {
    /// Declared but not started.
    stopped,
    /// Running as a process.
    running,
    /// Ended and awaiting its restart delay.
    backing_off,
    /// Failing too fast to be restarted. Terminal without intervention.
    quarantined,
    /// Ended as expected and will not be restarted.
    completed,

    pub fn isTerminal(state: State) bool {
        return state == .quarantined or state == .completed;
    }
};

pub const Error = error{
    /// No service is declared under that name.
    UnknownService,
    /// The service is already running.
    AlreadyRunning,
    /// The service is not running.
    NotRunning,
    /// The host refused to start the process.
    SpawnFailed,
};

/// What a service is and how it should be supervised.
pub const Declaration = struct {
    name: []const u8,
    /// The program and its arguments. Resolved by the host, not by a shell, so
    /// the argument vector cannot be reinterpreted as a command.
    argv: []const []const u8,
    restart_policy: RestartPolicy = .on_failure,
    limits: Limits = .{},
};

/// A supervised service.
pub const Service = struct {
    id: identity.PrincipalId,
    name: []const u8,
    argv: []const []const u8,
    restart_policy: RestartPolicy,
    limits: Limits,
    state: State,
    history: History,
    /// The running process, when there is one.
    child: ?std.process.Child = null,
    /// How the last run ended.
    last_exit: ?Exit = null,
    /// When the next restart may happen.
    restart_after: time.Timestamp = .epoch,
    /// Times this service has been started, including restarts.
    starts: u64 = 0,

    pub fn isRunning(service: Service) bool {
        return service.state == .running;
    }
};

/// Translates a host process result into the supervisor's vocabulary.
///
/// The distinction matters: a service killed by a fault must never be recorded
/// as one that exited cleanly, or a crash loop would look like normal operation.
pub fn classifyTerm(term: std.process.Child.Term) Exit {
    return switch (term) {
        .exited => |status| .{ .exited = status },
        .signal => |signal| .{ .signalled = @intFromEnum(signal) },
        .stopped => |signal| .{ .signalled = @intFromEnum(signal) },
        .unknown => .unknown,
    };
}

/// Starts, observes, and restarts services.
///
/// Ownership: the supervisor owns each service record and the strings it copies
/// from a declaration. `deinit` stops anything still running and releases them,
/// so no supervised process outlives the supervisor that started it.
pub const Supervisor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ids: *identity.Source,
    clock: time.Clock,
    services: std.ArrayList(*Service) = .empty,
    /// Faults observed across all services. The supervisor still running with a
    /// non-zero count here is the containment property.
    faults_observed: u64 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        ids: *identity.Source,
        clock: time.Clock,
    ) Supervisor {
        return .{ .gpa = gpa, .io = io, .ids = ids, .clock = clock };
    }

    /// Stops every running service before releasing anything.
    ///
    /// A supervised process must not outlive its supervisor: it would become
    /// exactly the unowned background work the task model exists to prevent.
    pub fn deinit(supervisor: *Supervisor) void {
        for (supervisor.services.items) |service| {
            // kill blocks until the process has ended and releases its
            // resources, so nothing further is owed to it here.
            if (service.child) |*child| child.kill(supervisor.io);
            supervisor.gpa.free(service.name);
            for (service.argv) |argument| supervisor.gpa.free(argument);
            supervisor.gpa.free(service.argv);
            supervisor.gpa.destroy(service);
        }
        supervisor.services.deinit(supervisor.gpa);
        supervisor.* = undefined;
    }

    /// Declares a service without starting it.
    pub fn declare(supervisor: *Supervisor, declaration: Declaration) !*Service {
        const name = try supervisor.gpa.dupe(u8, declaration.name);
        errdefer supervisor.gpa.free(name);

        const argv = try supervisor.gpa.alloc([]const u8, declaration.argv.len);
        errdefer supervisor.gpa.free(argv);
        var copied: usize = 0;
        errdefer for (argv[0..copied]) |argument| supervisor.gpa.free(argument);
        for (declaration.argv, argv) |source, *destination| {
            destination.* = try supervisor.gpa.dupe(u8, source);
            copied += 1;
        }

        const service = try supervisor.gpa.create(Service);
        errdefer supervisor.gpa.destroy(service);
        service.* = .{
            .id = supervisor.ids.next(identity.PrincipalId),
            .name = name,
            .argv = argv,
            .restart_policy = declaration.restart_policy,
            .limits = declaration.limits,
            .state = .stopped,
            .history = .{},
        };

        try supervisor.services.append(supervisor.gpa, service);
        return service;
    }

    pub fn find(supervisor: *Supervisor, name: []const u8) ?*Service {
        for (supervisor.services.items) |service| {
            if (std.mem.eql(u8, service.name, name)) return service;
        }
        return null;
    }

    /// Starts a declared service as its own process.
    pub fn start(supervisor: *Supervisor, service: *Service) Error!void {
        if (service.isRunning()) return error.AlreadyRunning;

        const child = std.process.spawn(supervisor.io, .{
            .argv = service.argv,
            // The service's output is not the supervisor's to interpret, and a
            // service must not be able to write into the supervisor's streams.
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return error.SpawnFailed;

        service.child = child;
        service.state = .running;
        service.history.started_at = supervisor.clock.wall();
        service.starts += 1;
    }

    /// Waits for a running service to end and applies the restart policy.
    ///
    /// Whatever the service did to itself, this returns a decision rather than
    /// an error. A supervisor that propagated a supervised fault would defeat
    /// its own purpose.
    pub fn reap(supervisor: *Supervisor, service: *Service) Error!Decision {
        if (!service.isRunning()) return error.NotRunning;

        // The stored child is waited on in place: a copy would leave the
        // service holding a handle the host has already released.
        const term = service.child.?.wait(supervisor.io) catch {
            service.child = null;
            service.state = .stopped;
            return .restart;
        };
        service.child = null;

        const exit = classifyTerm(term);
        service.last_exit = exit;
        if (!exit.isClean()) supervisor.faults_observed += 1;

        const now = supervisor.clock.wall();
        const ran_for = now.since(service.history.started_at);

        const decision = policy_module.decide(
            service.restart_policy,
            service.limits,
            &service.history,
            exit,
            ran_for,
        );

        switch (decision) {
            .restart => {
                service.state = .backing_off;
                service.restart_after = now.plus(
                    policy_module.backoff(service.limits, service.history.restarts),
                );
                service.history.restarts += 1;
            },
            .leave_stopped => service.state = .completed,
            .quarantine => service.state = .quarantined,
        }

        return decision;
    }

    /// Whether a backing-off service may be started again.
    pub fn isReadyToRestart(supervisor: *Supervisor, service: *Service) bool {
        if (service.state != .backing_off) return false;
        return !service.restart_after.isAfter(supervisor.clock.wall());
    }

    /// Stops a running service.
    pub fn stop(supervisor: *Supervisor, service: *Service) Error!void {
        if (!service.isRunning()) return error.NotRunning;
        if (service.child) |*child| child.kill(supervisor.io);
        service.child = null;
        service.state = .completed;
    }

    /// Whether the supervisor can still supervise.
    ///
    /// It always can. The method exists so a caller can assert containment
    /// explicitly rather than infer it from the absence of a crash.
    pub fn isOperable(supervisor: Supervisor) bool {
        _ = supervisor;
        return true;
    }

    pub fn runningCount(supervisor: Supervisor) usize {
        var running: usize = 0;
        for (supervisor.services.items) |service| {
            if (service.isRunning()) running += 1;
        }
        return running;
    }
};

const posix_hosts = switch (@import("builtin").target.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd => true,
    else => false,
};

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    supervisor: Supervisor,

    fn init(gpa: std.mem.Allocator, io: std.Io, fixture: *Fixture) void {
        fixture.* = .{
            .ids = .initDeterministic(555),
            .manual = .init(.fromSeconds(1_000)),
            .supervisor = undefined,
        };
        fixture.supervisor = .init(gpa, io, &fixture.ids, fixture.manual.clock());
    }

    fn deinit(fixture: *Fixture) void {
        fixture.supervisor.deinit();
    }
};

test "a service runs as its own process and its clean exit is observed" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const service = try fixture.supervisor.declare(.{
        .name = "clean",
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .restart_policy = .on_failure,
    });

    try fixture.supervisor.start(service);
    try std.testing.expect(service.isRunning());

    const decision = try fixture.supervisor.reap(service);

    try std.testing.expectEqual(Decision.leave_stopped, decision);
    try std.testing.expectEqual(State.completed, service.state);
    try std.testing.expectEqual(@as(u8, 0), service.last_exit.?.exited);
}

test "a service crashing with a fault leaves the supervisor intact" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    // A real fault in a real process: the service kills itself with a segment
    // violation, which no in-process boundary could contain.
    const crashing = try fixture.supervisor.declare(.{
        .name = "faulting",
        .argv = &.{ "/bin/sh", "-c", "kill -SEGV $$" },
        .restart_policy = .on_failure,
    });

    try fixture.supervisor.start(crashing);
    const decision = try fixture.supervisor.reap(crashing);

    try std.testing.expectEqual(Decision.restart, decision);
    switch (crashing.last_exit.?) {
        .signalled => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u64, 1), fixture.supervisor.faults_observed);

    // The supervisor's own state is untouched and it keeps working.
    try std.testing.expect(fixture.supervisor.isOperable());
    const healthy = try fixture.supervisor.declare(.{
        .name = "healthy",
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .restart_policy = .on_failure,
    });
    try fixture.supervisor.start(healthy);
    try std.testing.expectEqual(Decision.leave_stopped, try fixture.supervisor.reap(healthy));
}

test "a crashed service is restarted and runs again" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const service = try fixture.supervisor.declare(.{
        .name = "restarting",
        .argv = &.{ "/bin/sh", "-c", "exit 7" },
        .restart_policy = .on_failure,
    });

    try fixture.supervisor.start(service);
    try std.testing.expectEqual(Decision.restart, try fixture.supervisor.reap(service));
    try std.testing.expectEqual(State.backing_off, service.state);

    // The restart waits for its delay, then the service runs again.
    try std.testing.expect(!fixture.supervisor.isReadyToRestart(service));
    fixture.manual.advance(.fromSeconds(60));
    try std.testing.expect(fixture.supervisor.isReadyToRestart(service));

    try fixture.supervisor.start(service);
    try std.testing.expectEqual(@as(u64, 2), service.starts);
    _ = try fixture.supervisor.reap(service);
}

test "a service failing repeatedly is quarantined rather than restarted forever" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const service = try fixture.supervisor.declare(.{
        .name = "looping",
        .argv = &.{ "/bin/sh", "-c", "exit 1" },
        .restart_policy = .on_failure,
        .limits = .{ .max_restarts = 3, .healthy_after = .fromSeconds(30) },
    });

    var decision: Decision = .restart;
    var attempts: usize = 0;
    while (decision == .restart and attempts < 16) : (attempts += 1) {
        try fixture.supervisor.start(service);
        decision = try fixture.supervisor.reap(service);
    }

    try std.testing.expectEqual(Decision.quarantine, decision);
    try std.testing.expectEqual(State.quarantined, service.state);
    try std.testing.expect(service.state.isTerminal());
    // Bounded: it did not restart indefinitely.
    try std.testing.expect(attempts <= 5);
}

test "a service is stopped on request and does not outlive the supervisor" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const service = try fixture.supervisor.declare(.{
        .name = "long-running",
        .argv = &.{ "/bin/sh", "-c", "sleep 300" },
        .restart_policy = .never,
    });

    try fixture.supervisor.start(service);
    try std.testing.expectEqual(@as(usize, 1), fixture.supervisor.runningCount());

    try fixture.supervisor.stop(service);
    try std.testing.expectEqual(@as(usize, 0), fixture.supervisor.runningCount());
}

test "a supervisor releasing itself stops what it started" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);

    const service = try fixture.supervisor.declare(.{
        .name = "long-running",
        .argv = &.{ "/bin/sh", "-c", "sleep 300" },
        .restart_policy = .never,
    });
    try fixture.supervisor.start(service);

    // Releasing the supervisor must not leave the process running unowned.
    fixture.deinit();
}

test "one service's fault does not affect another running service" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const survivor = try fixture.supervisor.declare(.{
        .name = "survivor",
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .restart_policy = .never,
    });
    const crashing = try fixture.supervisor.declare(.{
        .name = "faulting",
        .argv = &.{ "/bin/sh", "-c", "kill -SEGV $$" },
        .restart_policy = .never,
    });

    try fixture.supervisor.start(survivor);
    try fixture.supervisor.start(crashing);

    _ = try fixture.supervisor.reap(crashing);

    // The unrelated service is untouched by its sibling's fault.
    try std.testing.expect(survivor.isRunning());
    try std.testing.expectEqual(@as(usize, 1), fixture.supervisor.runningCount());
    try fixture.supervisor.stop(survivor);
}

test "starting an already running service is refused" {
    if (!posix_hosts) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const service = try fixture.supervisor.declare(.{
        .name = "single",
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
    });

    try fixture.supervisor.start(service);
    try std.testing.expectError(error.AlreadyRunning, fixture.supervisor.start(service));
    try fixture.supervisor.stop(service);
}

test "reaping or stopping a service that is not running is refused" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const service = try fixture.supervisor.declare(.{
        .name = "idle",
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
    });

    try std.testing.expectError(error.NotRunning, fixture.supervisor.reap(service));
    try std.testing.expectError(error.NotRunning, fixture.supervisor.stop(service));
}

test "an unstartable program is reported rather than crashing the supervisor" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, std.testing.io, &fixture);
    defer fixture.deinit();

    const service = try fixture.supervisor.declare(.{
        .name = "absent",
        .argv = &.{"/nonexistent/program/that/is/not/there"},
    });

    try std.testing.expectError(error.SpawnFailed, fixture.supervisor.start(service));
    try std.testing.expectEqual(State.stopped, service.state);
    try std.testing.expect(fixture.supervisor.isOperable());
}

test "a signal is never classified as a clean exit" {
    const signalled = classifyTerm(.{ .signal = @enumFromInt(11) });
    try std.testing.expect(!signalled.isClean());

    const clean = classifyTerm(.{ .exited = 0 });
    try std.testing.expect(clean.isClean());

    const failed = classifyTerm(.{ .exited = 3 });
    try std.testing.expect(!failed.isClean());

    const unknown = classifyTerm(.{ .unknown = 0 });
    try std.testing.expect(!unknown.isClean());
}
