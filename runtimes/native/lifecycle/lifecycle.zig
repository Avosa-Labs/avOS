//! The lifecycle of a native component: declaring it, running it, and deciding
//! what to do when it ends, so a component that fails is restarted within bounds
//! rather than either abandoned or retried forever.
//!
//! The host runs a component once and returns how it ended; it does not decide
//! whether to run it again. That decision is lifecycle, and it is separate for a
//! reason. A component that completes is done. A component that failed may be worth
//! restarting — a transient fault, a resource spike that has passed — but only so
//! many times and only after a backoff, because a component that fails the instant
//! it starts would, restarted eagerly, become a busy loop that starves everything
//! else. So a failure is counted, restarts are spaced by a growing delay, and a
//! component that fails faster than it can be kept alive is quarantined: taken out
//! of the restart rotation until something outside intervenes.
//!
//! This module runs no component itself; it drives the host and holds the state a
//! restart decision is made from. Containment stays the host's: a component's
//! failure is an outcome here, never an error that propagates, so managing a
//! failing component cannot itself fail the runner.

const std = @import("std");
const core = @import("core");
const host_module = @import("../host/host.zig");

const identity = core.identity;

pub const Host = host_module.Host;
pub const Component = host_module.Component;
pub const Outcome = host_module.Outcome;
pub const CancellationToken = host_module.CancellationToken;

/// What to do with a component when a run ends.
pub const RestartPolicy = enum {
    /// Never restart: one run, then done whatever the outcome.
    never,
    /// Restart only after a failure; a clean completion is left completed.
    on_failure,
    /// Restart after any end, success or failure. For a component meant to run
    /// continuously, where a clean return is itself unexpected.
    always,
};

/// How far a component is through its lifecycle.
pub const State = enum {
    /// Declared, not yet run.
    idle,
    /// Ran and ended cleanly; will not be restarted.
    completed,
    /// Ended and is waiting out its restart backoff.
    backing_off,
    /// Failing too fast to keep alive. Out of rotation until intervention.
    quarantined,

    pub fn isTerminal(state: State) bool {
        return state == .completed or state == .quarantined;
    }
};

/// The bounds a component is restarted within.
pub const Limits = struct {
    /// The most consecutive failures before quarantine.
    max_restarts: u32 = 5,
    /// The base restart delay in milliseconds; the actual delay grows with the
    /// consecutive-failure count so a persistently failing component backs off.
    base_backoff_ms: u64 = 100,
    /// A ceiling on the backoff so it does not grow without bound.
    max_backoff_ms: u64 = 30_000,
};

/// Computes the backoff after a given number of consecutive failures: the base
/// delay doubled per failure, capped. Doubling makes a persistent failure back off
/// fast; the cap keeps the delay bounded.
pub fn backoff(limits: Limits, consecutive_failures: u32) u64 {
    if (consecutive_failures == 0) return 0;
    var delay = limits.base_backoff_ms;
    var doublings: u32 = consecutive_failures - 1;
    while (doublings > 0) : (doublings -= 1) {
        // Saturating double, then clamp, so a large failure count cannot overflow.
        delay = std.math.mul(u64, delay, 2) catch limits.max_backoff_ms;
        if (delay >= limits.max_backoff_ms) return limits.max_backoff_ms;
    }
    return @min(delay, limits.max_backoff_ms);
}

/// A component under lifecycle management.
pub const Managed = struct {
    component: Component,
    policy: RestartPolicy,
    limits: Limits,
    state: State = .idle,
    /// Consecutive failures since the last clean run. Reset by a completion.
    consecutive_failures: u32 = 0,
    /// Total runs started, including restarts.
    runs: u64 = 0,
    /// The milliseconds to wait before the next restart may start.
    next_backoff_ms: u64 = 0,
    last_outcome: ?Outcome = null,
};

/// What a run decided about the component's future.
pub const Decision = enum {
    /// The component finished and will not run again.
    done,
    /// The component will be restarted after its backoff.
    will_restart,
    /// The component is failing too fast and has been quarantined.
    quarantined,
};

/// Manages the lifecycle of native components over a host.
pub const Runner = struct {
    gpa: std.mem.Allocator,
    host: Host,
    managed: std.ArrayListUnmanaged(*Managed) = .empty,

    pub fn init(gpa: std.mem.Allocator) Runner {
        return .{ .gpa = gpa, .host = Host.init(gpa) };
    }

    pub fn deinit(runner: *Runner) void {
        for (runner.managed.items) |entry| runner.gpa.destroy(entry);
        runner.managed.deinit(runner.gpa);
        runner.* = undefined;
    }

    /// Declares a component to be managed, without running it.
    pub fn declare(runner: *Runner, component: Component, policy: RestartPolicy, limits: Limits) !*Managed {
        const entry = try runner.gpa.create(Managed);
        errdefer runner.gpa.destroy(entry);
        entry.* = .{ .component = component, .policy = policy, .limits = limits };
        try runner.managed.append(runner.gpa, entry);
        return entry;
    }

    /// Runs a managed component once and applies its restart policy to the outcome.
    ///
    /// The run is the host's; the decision is this runner's. A clean completion
    /// resets the failure count and, unless the policy restarts always, leaves the
    /// component completed. A failure is counted: once the consecutive-failure count
    /// exceeds the limit the component is quarantined, otherwise it is set to back
    /// off for a delay that grows with the count. Whatever happens, an outcome is
    /// recorded and a decision returned — never an error.
    pub fn runOnce(runner: *Runner, entry: *Managed, cancellation: *const CancellationToken) Decision {
        entry.runs += 1;
        const outcome = runner.host.run(entry.component, cancellation);
        entry.last_outcome = outcome;

        if (outcome.succeeded()) {
            entry.consecutive_failures = 0;
            entry.next_backoff_ms = 0;
            if (entry.policy == .always) {
                entry.state = .backing_off;
                return .will_restart;
            }
            entry.state = .completed;
            return .done;
        }

        // A failure. Whether it restarts depends on the policy and the count.
        if (entry.policy == .never) {
            entry.state = .completed;
            return .done;
        }
        entry.consecutive_failures += 1;
        if (entry.consecutive_failures > entry.limits.max_restarts) {
            entry.state = .quarantined;
            return .quarantined;
        }
        entry.state = .backing_off;
        entry.next_backoff_ms = backoff(entry.limits, entry.consecutive_failures);
        return .will_restart;
    }

    /// Whether a backing-off component's delay has elapsed, given how long it has
    /// been waiting. A component not backing off is never ready here.
    pub fn isReadyToRestart(entry: *const Managed, waited_ms: u64) bool {
        if (entry.state != .backing_off) return false;
        return waited_ms >= entry.next_backoff_ms;
    }

    /// Clears a quarantine so a component may be tried again — the intervention the
    /// quarantine waits for.
    pub fn clearQuarantine(entry: *Managed) void {
        if (entry.state != .quarantined) return;
        entry.state = .idle;
        entry.consecutive_failures = 0;
        entry.next_backoff_ms = 0;
    }

    /// Runs started across every managed component.
    pub fn totalRuns(runner: Runner) u64 {
        var total: u64 = 0;
        for (runner.managed.items) |entry| total += entry.runs;
        return total;
    }
};

// --- Tests ---

const testing = std.testing;

var completes_calls: u32 = 0;
var faults_calls: u32 = 0;

fn completes(context: host_module.Context) host_module.Error!void {
    _ = context;
    completes_calls += 1;
}

fn faults(context: host_module.Context) host_module.Error!void {
    _ = context;
    faults_calls += 1;
    return error.Trapped;
}

fn componentFor(id: u64, name: []const u8, entry: host_module.EntryPoint) Component {
    return .{
        .id = .{ .value = id },
        .name = name,
        .entry = entry,
        .grant = .{},
        .memory_ceiling_bytes = 64 * 1024,
        .step_budget = 1000,
    };
}

test "a clean completion is not restarted under on-failure" {
    const gpa = testing.allocator;
    var runner = Runner.init(gpa);
    defer runner.deinit();

    const entry = try runner.declare(componentFor(1, "clean", completes), .on_failure, .{});
    var token: CancellationToken = .{};
    const decision = runner.runOnce(entry, &token);
    try testing.expectEqual(Decision.done, decision);
    try testing.expectEqual(State.completed, entry.state);
    try testing.expect(entry.state.isTerminal());
}

test "a failing component is restarted with a growing backoff, then quarantined" {
    const gpa = testing.allocator;
    var runner = Runner.init(gpa);
    defer runner.deinit();

    const entry = try runner.declare(componentFor(2, "faulty", faults), .on_failure, .{ .max_restarts = 3 });
    var token: CancellationToken = .{};

    var decision: Decision = .will_restart;
    var attempts: u32 = 0;
    var last_backoff: u64 = 0;
    while (decision == .will_restart and attempts < 16) : (attempts += 1) {
        decision = runner.runOnce(entry, &token);
        if (decision == .will_restart) {
            // The backoff never shrinks as failures accumulate.
            try testing.expect(entry.next_backoff_ms >= last_backoff);
            last_backoff = entry.next_backoff_ms;
        }
    }
    try testing.expectEqual(Decision.quarantined, decision);
    try testing.expectEqual(State.quarantined, entry.state);
    // Bounded: it did not restart indefinitely.
    try testing.expect(attempts <= 5);
}

test "a backing-off component is ready only once its delay elapses" {
    const gpa = testing.allocator;
    var runner = Runner.init(gpa);
    defer runner.deinit();

    const entry = try runner.declare(componentFor(3, "faulty", faults), .on_failure, .{ .base_backoff_ms = 200 });
    var token: CancellationToken = .{};
    _ = runner.runOnce(entry, &token);
    try testing.expectEqual(State.backing_off, entry.state);
    try testing.expect(!Runner.isReadyToRestart(entry, entry.next_backoff_ms - 1));
    try testing.expect(Runner.isReadyToRestart(entry, entry.next_backoff_ms));
}

test "clearing a quarantine lets a component be tried again" {
    const gpa = testing.allocator;
    var runner = Runner.init(gpa);
    defer runner.deinit();

    const entry = try runner.declare(componentFor(4, "faulty", faults), .on_failure, .{ .max_restarts = 1 });
    var token: CancellationToken = .{};
    _ = runner.runOnce(entry, &token); // fail 1
    _ = runner.runOnce(entry, &token); // fail 2 -> quarantine
    try testing.expectEqual(State.quarantined, entry.state);

    Runner.clearQuarantine(entry);
    try testing.expectEqual(State.idle, entry.state);
    try testing.expectEqual(@as(u32, 0), entry.consecutive_failures);
}

test "the backoff doubles per failure and is capped" {
    const limits: Limits = .{ .base_backoff_ms = 100, .max_backoff_ms = 1000 };
    try testing.expectEqual(@as(u64, 0), backoff(limits, 0));
    try testing.expectEqual(@as(u64, 100), backoff(limits, 1));
    try testing.expectEqual(@as(u64, 200), backoff(limits, 2));
    try testing.expectEqual(@as(u64, 400), backoff(limits, 3));
    try testing.expectEqual(@as(u64, 800), backoff(limits, 4));
    // Capped from here on.
    try testing.expectEqual(@as(u64, 1000), backoff(limits, 5));
    try testing.expectEqual(@as(u64, 1000), backoff(limits, 20));
}
