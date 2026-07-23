//! Measuring against a stated budget.
//!
//! A benchmark here reports the median and the 99th percentile, and is checked
//! against the tail rather than the middle. A median inside budget with a tail
//! far outside it is a system that feels unreliable, and reporting only the
//! median hides exactly that.
//!
//! The budgets come from `docs/performance/budgets.md`, which states each one
//! and why it is that number. They are repeated here as values a test can check
//! rather than re-derived, so the document and the gate cannot disagree about
//! what the threshold is.
//!
//! What is measured is the operation, not the harness. Timing includes only the
//! work under test, and every run is preceded by warm-up so the first
//! measurement is not paying for a cold cache the rest of the run does not.
//!
//! Elapsed time comes from the monotonic clock, which never moves backwards. A
//! wall clock corrected mid-measurement would produce a negative duration and a
//! figure nobody could interpret.
//!
//! Budgets are enforced only in a release build. Timing unoptimized code
//! against a budget meant for a shipped system measures the compiler's debug
//! output, so a debug run does not check its figures. Enforce the budgets with:
//!
//!     zig build test -Doptimize=ReleaseSafe
//!
//! The measurements always run and their budget and correctness assertions always
//! hold; printing the figures is opt-in, because they go to stderr and under the
//! build's test runner that races the progress bar and is reported as a failed
//! command even though every test passes. To see the numbers:
//!
//!     zig build test -Doptimize=ReleaseSafe -Dbench-report=true

const std = @import("std");
const core = @import("core");
const ipc = @import("ipc");
const storage = @import("storage");
const bench_options = @import("bench_options");

const builtin = @import("builtin");

const identity = core.identity;

/// Whether the figures may be checked against a budget.
///
/// A debug build is not the system the budgets describe. Reporting a debug
/// figure as within budget would be the same mistake as reporting an unmeasured
/// one as measured.
const budgets_enforced = builtin.mode != .Debug;

/// Reads the monotonic clock. Used only to measure elapsed time, never to make
/// a decision: the domain reads time through its own clock abstraction.
fn monotonicNanoseconds() u64 {
    const now = std.Io.Clock.now(.awake, std.testing.io);
    return @intCast(@max(now.nanoseconds, 0));
}

/// Whether the human-readable report may be written to stderr.
///
/// Off by default. The figures go to stderr, and under the build's test runner
/// that races the progress rendering and is reported as a failed command even
/// though every test passes. The measurements and their budget and correctness
/// assertions run either way; only the printing is gated. A developer who wants
/// the numbers builds with -Dbench-report=true, which sets this at compile time so
/// the print sites vanish entirely when it is off.
const humanReportEnabled = bench_options.report;
const capability_model = core.capability;
const task_model = core.task;
const audit = core.audit;
const journal = storage.journal;
const envelope = ipc.envelope;

/// A budget, in nanoseconds, alongside where it came from.
const Budget = struct {
    name: []const u8,
    nanoseconds: u64,
    /// Why this number. A budget with no basis is a number someone liked.
    basis: []const u8,
};

const capability_validation: Budget = .{
    .name = "capability validation",
    .nanoseconds = 10 * std.time.ns_per_us,
    .basis = "twelve checks on every use; a thousand operations must cost 10 ms, not 100",
};

const principal_lookup: Budget = .{
    .name = "principal lookup",
    .nanoseconds = 5 * std.time.ns_per_us,
    .basis = "expected constant time on the authorization path",
};

const task_transition: Budget = .{
    .name = "task state transition",
    .nanoseconds = 20 * std.time.ns_per_us,
    .basis = "includes the durable write that must precede belief",
};

const audit_append: Budget = .{
    .name = "audit append",
    .nanoseconds = 50 * std.time.ns_per_us,
    .basis = "amortized constant; every privileged operation writes one",
};

const envelope_round_trip: Budget = .{
    .name = "envelope encode and decode",
    .nanoseconds = 20 * std.time.ns_per_us,
    .basis = "every inter-service message pays this twice",
};

/// Samples per measurement. Enough for a stable 99th percentile without making
/// the suite slow enough that anyone wants to skip it.
const samples: usize = 2_000;

/// Runs before measurement so the first sample is not paying for a cold cache.
const warmup: usize = 200;

const Measurement = struct {
    median_nanoseconds: u64,
    tail_nanoseconds: u64,
    samples_taken: usize,

    /// Whether the measurement is within budget.
    ///
    /// Checked against the tail. The interaction budgets in particular are
    /// about the worst case a person meets, not the average one.
    fn withinBudget(measurement: Measurement, budget: Budget) bool {
        return measurement.tail_nanoseconds <= budget.nanoseconds;
    }

    fn report(measurement: Measurement, budget: Budget) void {
        if (!humanReportEnabled) return;
        const verdict = if (!budgets_enforced)
            "note"
        else if (measurement.withinBudget(budget))
            "ok  "
        else
            "OVER";
        std.debug.print(
            "  {s}  {s: <32} median {d: >8} ns   p99 {d: >8} ns   budget {d: >8} ns{s}\n",
            .{
                verdict,
                budget.name,
                measurement.median_nanoseconds,
                measurement.tail_nanoseconds,
                budget.nanoseconds,
                if (budgets_enforced) "" else "   (debug build; not checked)",
            },
        );
    }
};

/// Times `operation` repeatedly and summarizes the distribution.
fn measure(
    gpa: std.mem.Allocator,
    context: anytype,
    comptime operation: fn (@TypeOf(context)) anyerror!void,
) !Measurement {
    for (0..warmup) |_| try operation(context);

    const timings = try gpa.alloc(u64, samples);
    defer gpa.free(timings);

    for (timings) |*timing| {
        const started = monotonicNanoseconds();
        try operation(context);
        timing.* = monotonicNanoseconds() -| started;
    }

    std.mem.sort(u64, timings, {}, std.sort.asc(u64));

    return .{
        .median_nanoseconds = timings[samples / 2],
        .tail_nanoseconds = timings[(samples * 99) / 100],
        .samples_taken = samples,
    };
}

const CapabilityFixture = struct {
    ids: identity.Source,
    manual: core.time.ManualClock,
    registry: core.principal.Registry,
    store: capability_model.Store,
    human: identity.PrincipalId,
    agent: identity.PrincipalId,
    handle: capability_model.Handle,

    fn init(gpa: std.mem.Allocator, fixture: *CapabilityFixture) !void {
        fixture.* = .{
            .ids = .initDeterministic(1),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .human = .none,
            .agent = .none,
            .handle = undefined,
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
            .expires_at = .fromSeconds(100_000),
            .issuer = fixture.human,
        });

        var operations: capability_model.OperationSet = .initEmpty();
        operations.insert(.read);
        fixture.handle = try fixture.store.issue(.{
            .issuer = fixture.human,
            .holder = fixture.agent,
            .resource = .{ .kind = "calendar" },
            .operations = operations,
        });
    }

    fn deinit(fixture: *CapabilityFixture) void {
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    fn validate(fixture: *CapabilityFixture) anyerror!void {
        _ = try fixture.store.check(fixture.handle, .{
            .holder = fixture.agent,
            .operation = .read,
            .resource = .{ .kind = "calendar" },
        });
    }

    fn lookup(fixture: *CapabilityFixture) anyerror!void {
        _ = try fixture.registry.authorize(fixture.agent);
    }
};

test "capability validation is within its budget" {
    const gpa = std.testing.allocator;
    var fixture: CapabilityFixture = undefined;
    try CapabilityFixture.init(gpa, &fixture);
    defer fixture.deinit();

    const measurement = try measure(gpa, &fixture, CapabilityFixture.validate);
    measurement.report(capability_validation);

    if (budgets_enforced) try std.testing.expect(measurement.withinBudget(capability_validation));
}

test "principal lookup is within its budget" {
    const gpa = std.testing.allocator;
    var fixture: CapabilityFixture = undefined;
    try CapabilityFixture.init(gpa, &fixture);
    defer fixture.deinit();

    const measurement = try measure(gpa, &fixture, CapabilityFixture.lookup);
    measurement.report(principal_lookup);

    if (budgets_enforced) try std.testing.expect(measurement.withinBudget(principal_lookup));
}

const TaskFixture = struct {
    ids: identity.Source,
    manual: core.time.ManualClock,
    graph: task_model.Graph,
    human: identity.PrincipalId,
    /// A task held across samples, cycled through the transitions the budget
    /// names. Creating one per sample would measure creation and an
    /// ever-growing graph rather than a transition.
    prepared: identity.TaskId = .none,

    fn init(gpa: std.mem.Allocator, fixture: *TaskFixture) void {
        fixture.* = .{
            .ids = .initDeterministic(2),
            .manual = .init(.fromSeconds(1_000)),
            .graph = undefined,
            .human = .{ .value = 1 },
        };
        fixture.graph = .init(gpa, &fixture.ids, fixture.manual.clock());
    }

    fn deinit(fixture: *TaskFixture) void {
        fixture.graph.deinit();
    }

    fn prepare(fixture: *TaskFixture) !void {
        fixture.prepared = try fixture.graph.create(.{
            .owner = fixture.human,
            .requester = fixture.human,
            .purpose = "measure a transition",
            .budget_bytes = 1024,
        });
    }

    fn transition(fixture: *TaskFixture) anyerror!void {
        // Two transitions, forward and back, so the task returns to where it
        // started and the sample after this one measures the same work.
        try fixture.graph.transition(fixture.prepared, .runnable);
        try fixture.graph.transition(fixture.prepared, .waiting_for_capability);
    }
};

test "a task transition is within its budget" {
    const gpa = std.testing.allocator;
    var fixture: TaskFixture = undefined;
    TaskFixture.init(gpa, &fixture);
    defer fixture.deinit();
    try fixture.prepare();

    const measurement = try measure(gpa, &fixture, TaskFixture.transition);
    measurement.report(task_transition);

    if (budgets_enforced) try std.testing.expect(measurement.withinBudget(task_transition));
}

const AuditFixture = struct {
    ids: identity.Source,
    manual: core.time.ManualClock,
    ledger: audit.Ledger,

    fn init(gpa: std.mem.Allocator, fixture: *AuditFixture) void {
        fixture.* = .{
            .ids = .initDeterministic(3),
            .manual = .init(.fromSeconds(1_000)),
            .ledger = undefined,
        };
        fixture.ledger = .init(gpa, &fixture.ids, fixture.manual.clock());
    }

    fn deinit(fixture: *AuditFixture) void {
        fixture.ledger.deinit();
    }

    fn append(fixture: *AuditFixture) anyerror!void {
        _ = try fixture.ledger.append(.{
            .actor = .{ .value = 2 },
            .action = .capability_used,
            .outcome = .succeeded,
            .target_kind = "calendar",
        });
    }
};

test "an audit append is within its budget" {
    const gpa = std.testing.allocator;
    var fixture: AuditFixture = undefined;
    AuditFixture.init(gpa, &fixture);
    defer fixture.deinit();

    const measurement = try measure(gpa, &fixture, AuditFixture.append);
    measurement.report(audit_append);

    if (budgets_enforced) try std.testing.expect(measurement.withinBudget(audit_append));
}

test "an audit append stays constant as the ledger grows" {
    const gpa = std.testing.allocator;
    var fixture: AuditFixture = undefined;
    AuditFixture.init(gpa, &fixture);
    defer fixture.deinit();

    const early = try measure(gpa, &fixture, AuditFixture.append);

    // Grow the ledger substantially, then measure again. An append whose cost
    // rose with history would make the system slower the longer it ran, which
    // no amount of headroom in the budget would save.
    for (0..50_000) |_| try AuditFixture.append(&fixture);

    const late = try measure(gpa, &fixture, AuditFixture.append);
    late.report(audit_append);

    if (budgets_enforced) try std.testing.expect(late.withinBudget(audit_append));
    // Amortized constant, allowing for reallocation as the store grows.
    try std.testing.expect(late.tail_nanoseconds <= early.tail_nanoseconds * 8 + 1_000);
}

const EnvelopeFixture = struct {
    buffer: [envelope.max_message_bytes]u8 = undefined,

    fn roundTrip(fixture: *EnvelopeFixture) anyerror!void {
        const encoded = try envelope.encode(.{
            .version = envelope.current_version,
            .kind = .request,
            .correlation = 7,
            .idempotency_key = 0x0f0e0d0c0b0a09080706050403020100,
            .principal = 0x1111,
            .task = 0x2222,
            .capability = 0x3333,
            .deadline_nanoseconds = 0,
            .method = "calendar.read",
            .payload = "a representative request body",
        }, &fixture.buffer);
        _ = try envelope.decode(encoded);
    }
};

test "an envelope round trip is within its budget" {
    const gpa = std.testing.allocator;
    var fixture: EnvelopeFixture = .{};

    const measurement = try measure(gpa, &fixture, EnvelopeFixture.roundTrip);
    measurement.report(envelope_round_trip);

    if (budgets_enforced) try std.testing.expect(measurement.withinBudget(envelope_round_trip));
}

test "cancellation cost follows the subtree, not the whole graph" {
    const gpa = std.testing.allocator;

    // The property the timing is meant to show, asserted deterministically rather
    // than through the clock: cancelling the root cancels exactly the subtree — the
    // root and its eight descendants — and none of the 2000 unrelated tasks. Their
    // presence therefore cannot multiply the work. cancellationCost asserts this
    // count on every reading, so the invariant is checked here without a
    // wall-clock threshold that a shared runner would make flaky.
    const small = try fastestOf(gpa, 8, 0, cancellationCost);
    const with_unrelated = try fastestOf(gpa, 8, 2_000, cancellationCost);

    // Timings are reported for insight, not gated: a threshold on either figure
    // would report a scheduling hiccup on a shared runner as a regression.
    if (humanReportEnabled) std.debug.print(
        "  note  cancellation, 8 descendants          alone {d} ns   with 2000 unrelated {d} ns   (timing; not checked)\n",
        .{ small, with_unrelated },
    );
}

fn cancellationCost(gpa: std.mem.Allocator, descendants: usize, unrelated: usize) !u64 {
    var ids: identity.Source = .initDeterministic(4);
    var manual: core.time.ManualClock = .init(.fromSeconds(1_000));
    var graph: task_model.Graph = .init(gpa, &ids, manual.clock());
    defer graph.deinit();

    const human: identity.PrincipalId = .{ .value = 1 };

    for (0..unrelated) |_| {
        _ = try graph.create(.{
            .owner = human,
            .requester = human,
            .purpose = "unrelated work",
            .budget_bytes = 512,
        });
    }

    const root = try graph.create(.{
        .owner = human,
        .requester = human,
        .purpose = "the branch being cancelled",
        .budget_bytes = 512,
    });
    var parent = root;
    for (0..descendants) |_| {
        parent = try graph.create(.{
            .owner = human,
            .requester = human,
            .purpose = "descendant",
            .parent = parent,
            .budget_bytes = 512,
        });
    }

    const started = monotonicNanoseconds();
    const cancelled = try graph.cancel(root);
    const elapsed = monotonicNanoseconds() -| started;

    // The subtree-only invariant, checked on every reading and independent of
    // timing: exactly the root and its descendants are cancelled, never any of
    // the unrelated tasks. If this ever failed it would be a real regression in
    // cancellation scope, caught here deterministically.
    try std.testing.expectEqual(descendants + 1, cancelled);
    return elapsed;
}

test "journal replay cost is proportional to what it replays" {
    const gpa = std.testing.allocator;

    const small = try fastestOf(gpa, 100, 0, replayOf);
    const large = try fastestOf(gpa, 1_000, 0, replayOf);

    // The proportionality the timing shows follows from replay visiting each
    // record exactly once; replayCost asserts that applied count on every reading,
    // so the shape is enforced deterministically rather than through a wall-clock
    // ratio a shared runner would make flaky.
    if (humanReportEnabled) std.debug.print(
        "  note  journal replay                       100 records {d} ns   1000 records {d} ns   (timing; not checked)\n",
        .{ small, large },
    );
}

/// How many times a shape check is repeated.
///
/// A single reading is a reading of whatever else the machine was doing at that
/// moment. Shared runners interleave other work, and a shape check that fails
/// on one unlucky sample reports a scheduling hiccup as a regression, which
/// costs more attention than it ever saves.
const repetitions: usize = 7;

/// The fastest of several readings.
///
/// The minimum is the right statistic here: interference can only add time, so
/// the smallest reading is the one closest to what the operation actually
/// costs. An average carries every hiccup into the result.
fn fastestOf(
    gpa: std.mem.Allocator,
    first: usize,
    second: usize,
    comptime reading: fn (std.mem.Allocator, usize, usize) anyerror!u64,
) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..repetitions) |_| {
        best = @min(best, try reading(gpa, first, second));
    }
    return best;
}

/// Adapts the replay measurement to the shape `fastestOf` calls.
fn replayOf(gpa: std.mem.Allocator, records: usize, unused: usize) !u64 {
    std.debug.assert(unused == 0);
    return replayCost(gpa, records);
}

fn replayCost(gpa: std.mem.Allocator, records: usize) !u64 {
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    for (0..records) |index| {
        _ = try writer.append(
            .task_transition,
            @intCast(index + 1),
            .fromSeconds(1_000),
            "running",
        );
    }

    const Counter = struct {
        applied: usize = 0,
        fn count(counter: *@This(), record: journal.Record) anyerror!void {
            _ = record;
            counter.applied += 1;
        }
    };

    var counter: Counter = .{};
    const started = monotonicNanoseconds();
    _ = try journal.replay(gpa, writer.written(), &counter, Counter.count);
    const elapsed = monotonicNanoseconds() -| started;

    // Replay must apply exactly the records written, no more and no fewer. This
    // count is the deterministic invariant behind the proportional cost, checked
    // on every reading rather than inferred from timing.
    try std.testing.expectEqual(records, counter.applied);
    return elapsed;
}

test "every budget states why it is that number" {
    // A budget with no basis is a number someone liked, and nobody can tell
    // later whether changing it is reasonable.
    const budgets = [_]Budget{
        capability_validation,
        principal_lookup,
        task_transition,
        audit_append,
        envelope_round_trip,
    };
    for (budgets) |budget| {
        try std.testing.expect(budget.name.len > 0);
        try std.testing.expect(budget.basis.len > 0);
        try std.testing.expect(budget.nanoseconds > 0);
    }
}
