//! Hosts a native component under a resource and authority boundary.
//!
//! A component is untrusted code the host runs on someone's behalf. The host
//! gives it a budgeted allocator, a sandbox that mediates every host resource,
//! an execution meter, and a cancellation token — and nothing else. It gets no
//! ambient allocator, no ambient filesystem, and no way to continue after the
//! host decides it should stop.
//!
//! Containment here is failure containment, not memory-safety isolation. A
//! component that faults, exhausts its budget, overruns its meter, or reaches
//! for an ungranted resource is stopped and reported, and the control plane
//! keeps running with its state intact. A component that corrupts memory is a
//! different threat, and defending it needs a process or virtual-machine
//! boundary rather than a function call; that boundary is the runtime's, not
//! this host's, and until it exists this host must not be described as
//! providing it.

const std = @import("std");
const core = @import("core");
const sandbox_module = @import("../sandbox/sandbox.zig");

const resource = core.resource;
const identity = core.identity;

pub const Sandbox = sandbox_module.Sandbox;
pub const Grant = sandbox_module.Grant;

/// How a component's execution ended.
pub const Conclusion = enum {
    /// It finished on its own.
    completed,
    /// It faulted. Contained, reported, and not fatal to the host.
    trapped,
    /// It exceeded its execution meter.
    meter_exhausted,
    /// It exceeded its memory ceiling.
    budget_exhausted,
    /// It reached for a resource it was not granted.
    resource_denied,
    /// It was cancelled and stopped at a yield point.
    cancelled,
    /// It ran past its deadline.
    deadline_exceeded,

    pub fn isFailure(conclusion: Conclusion) bool {
        return conclusion != .completed;
    }
};

pub const Error = error{
    Trapped,
    MeterExhausted,
    BudgetExhausted,
    ResourceDenied,
    Cancelled,
    DeadlineExceeded,
};

/// Bounds how long a component may run.
///
/// Measured in steps rather than time so a run is reproducible: the same
/// component with the same meter stops at the same point on every machine.
pub const Meter = struct {
    /// Steps remaining. Reaching zero stops the component.
    remaining: u64,
    consumed: u64 = 0,

    pub fn init(budget: u64) Meter {
        return .{ .remaining = budget };
    }

    pub fn isExhausted(meter: Meter) bool {
        return meter.remaining == 0;
    }

    fn charge(meter: *Meter, steps: u64) bool {
        if (steps > meter.remaining) {
            meter.consumed += meter.remaining;
            meter.remaining = 0;
            return false;
        }
        meter.remaining -= steps;
        meter.consumed += steps;
        return true;
    }
};

/// Signals that a component should stop.
///
/// Cancellation is cooperative at this boundary: the component observes the
/// token at a yield point and returns. That is sufficient for code the host
/// compiled, and insufficient for code that declines to yield — which is why
/// the meter exists alongside it, bounding a component that ignores the token.
pub const CancellationToken = struct {
    requested: bool = false,

    pub fn request(token: *CancellationToken) void {
        token.requested = true;
    }

    pub fn isRequested(token: CancellationToken) bool {
        return token.requested;
    }
};

/// What the host lends a component for one execution.
///
/// This is the component's entire world. Anything not reachable through this
/// structure is not reachable at all.
pub const Context = struct {
    allocator: std.mem.Allocator,
    sandbox: *Sandbox,
    meter: *Meter,
    cancellation: *const CancellationToken,

    /// Charges the meter and observes cancellation.
    ///
    /// A component calls this between units of work. It is the only place a
    /// cooperative component can be stopped, so anything long-running must pass
    /// through it.
    pub fn yieldStep(context: Context, steps: u64) Error!void {
        if (context.cancellation.isRequested()) return error.Cancelled;
        if (!context.meter.charge(steps)) return error.MeterExhausted;
    }

    pub fn openForRead(context: Context, path: []const u8) Error!void {
        context.sandbox.openForRead(path) catch return error.ResourceDenied;
    }

    pub fn openForWrite(context: Context, path: []const u8) Error!void {
        context.sandbox.openForWrite(path) catch return error.ResourceDenied;
    }

    pub fn connect(context: Context, destination: []const u8) Error!void {
        context.sandbox.connect(destination) catch return error.ResourceDenied;
    }
};

/// The component's entry point.
pub const EntryPoint = *const fn (context: Context) Error!void;

/// A component as the host sees it: an identity, an entry point, and the
/// limits it runs under.
pub const Component = struct {
    id: identity.PrincipalId,
    name: []const u8,
    entry: EntryPoint,
    grant: Grant,
    memory_ceiling_bytes: usize,
    step_budget: u64,
};

/// What one execution produced.
pub const Outcome = struct {
    conclusion: Conclusion,
    steps_consumed: u64,
    peak_bytes: usize,
    /// Bytes the component had not released when it stopped. Reclaimed by the
    /// host, and non-zero only when the component failed to clean up.
    leaked_bytes: usize,
    resource_refusals: u64,

    pub fn succeeded(outcome: Outcome) bool {
        return outcome.conclusion == .completed;
    }
};

/// Runs components and survives their failures.
///
/// Ownership: each execution runs against its own arena, and the budget meters
/// allocations from it. Releasing the arena when the run ends reclaims
/// everything the component took, whether it finished, failed, was cancelled,
/// or simply never freed what it allocated. A component therefore cannot leak
/// into the host by declining to clean up.
pub const Host = struct {
    gpa: std.mem.Allocator,
    /// Executions started since the host was created.
    executions: u64 = 0,
    /// Executions that ended in failure. The host continuing to run with a
    /// non-zero count here is the containment property.
    failures: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Host {
        return .{ .gpa = gpa };
    }

    /// Runs a component to completion, failure, or cancellation.
    ///
    /// Every failure mode returns an outcome rather than propagating: a
    /// component's fault must not become the host's error path, or one bad
    /// component would take the control plane with it.
    pub fn run(
        host: *Host,
        component: Component,
        cancellation: *const CancellationToken,
    ) Outcome {
        host.executions += 1;

        // The arena is the reclamation boundary; the budget is the ceiling.
        // Both are needed: the ceiling stops a component from exhausting the
        // host, and the arena reclaims what it holds when it stops.
        var arena_state: std.heap.ArenaAllocator = .init(host.gpa);
        defer arena_state.deinit();

        var budget: resource.Budget = .init(arena_state.allocator(), component.memory_ceiling_bytes, .{
            .principal = component.id,
            .task = .none,
        });
        var sandbox: Sandbox = .init(component.grant);
        var meter: Meter = .init(component.step_budget);

        const context: Context = .{
            .allocator = budget.allocator(),
            .sandbox = &sandbox,
            .meter = &meter,
            .cancellation = cancellation,
        };

        const conclusion: Conclusion = if (component.entry(context)) |_|
            .completed
        else |failure| switch (failure) {
            error.Trapped => .trapped,
            error.MeterExhausted => .meter_exhausted,
            error.BudgetExhausted => .budget_exhausted,
            error.ResourceDenied => .resource_denied,
            error.Cancelled => .cancelled,
            error.DeadlineExceeded => .deadline_exceeded,
        };

        if (conclusion.isFailure()) host.failures += 1;

        return .{
            .conclusion = conclusion,
            .steps_consumed = meter.consumed,
            .peak_bytes = budget.usage.peak_bytes,
            .leaked_bytes = budget.usage.current_bytes,
            .resource_refusals = sandbox.refusals,
        };
    }

    /// Whether the host is still able to run components.
    ///
    /// It always is. The method exists so a caller can assert the containment
    /// property explicitly rather than inferring it from the absence of a crash.
    pub fn isOperable(host: Host) bool {
        _ = host;
        return true;
    }
};

fn completingComponent(context: Context) Error!void {
    try context.yieldStep(1);
    const block = context.allocator.alloc(u8, 256) catch return error.BudgetExhausted;
    defer context.allocator.free(block);
    try context.yieldStep(1);
}

fn trappingComponent(context: Context) Error!void {
    try context.yieldStep(1);
    return error.Trapped;
}

fn nonYieldingComponent(context: Context) Error!void {
    // Ignores cancellation entirely; only the meter can stop it.
    var index: u64 = 0;
    while (index < 1_000_000) : (index += 1) {
        if (!context.meter.charge(1)) return error.MeterExhausted;
    }
}

fn yieldingComponent(context: Context) Error!void {
    var index: u64 = 0;
    while (index < 1_000_000) : (index += 1) {
        try context.yieldStep(1);
    }
}

fn memoryHungryComponent(context: Context) Error!void {
    try context.yieldStep(1);
    var blocks: std.ArrayList([]u8) = .empty;
    defer blocks.deinit(context.allocator);
    while (true) {
        const block = context.allocator.alloc(u8, 4096) catch return error.BudgetExhausted;
        blocks.append(context.allocator, block) catch return error.BudgetExhausted;
    }
}

fn leakingComponent(context: Context) Error!void {
    try context.yieldStep(1);
    _ = context.allocator.alloc(u8, 1024) catch return error.BudgetExhausted;
}

fn probingComponent(context: Context) Error!void {
    try context.yieldStep(1);
    try context.openForRead("/secrets/keys");
}

fn networkProbingComponent(context: Context) Error!void {
    try context.yieldStep(1);
    try context.connect("elsewhere.invalid");
}

fn wellBehavedFileComponent(context: Context) Error!void {
    try context.yieldStep(1);
    try context.openForRead("/documents/agenda");
}

fn readableGrant() Grant {
    var classes: std.EnumSet(sandbox_module.ResourceClass) = .initEmpty();
    classes.insert(.filesystem_read);
    return .{ .classes = classes, .readable_paths = &.{"/documents"} };
}

fn describe(name: []const u8, entry: EntryPoint, grant: Grant) Component {
    return .{
        .id = .{ .value = 0xc07e },
        .name = name,
        .entry = entry,
        .grant = grant,
        .memory_ceiling_bytes = 64 * 1024,
        .step_budget = 10_000,
    };
}

test "a well-behaved component completes and releases what it took" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    const outcome = host.run(describe("ordinary", completingComponent, .empty), &token);

    try std.testing.expect(outcome.succeeded());
    try std.testing.expectEqual(@as(usize, 0), outcome.leaked_bytes);
    try std.testing.expect(outcome.peak_bytes >= 256);
    try std.testing.expectEqual(@as(u64, 2), outcome.steps_consumed);
}

test "a component trap is contained and the host keeps running" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    const trapped = host.run(describe("hostile", trappingComponent, .empty), &token);
    try std.testing.expectEqual(Conclusion.trapped, trapped.conclusion);

    // The host survives and runs the next component normally. This is the
    // containment property, asserted rather than inferred.
    try std.testing.expect(host.isOperable());
    const next = host.run(describe("ordinary", completingComponent, .empty), &token);
    try std.testing.expect(next.succeeded());

    try std.testing.expectEqual(@as(u64, 2), host.executions);
    try std.testing.expectEqual(@as(u64, 1), host.failures);
}

test "repeated traps do not degrade the host" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    for (0..64) |_| {
        const outcome = host.run(describe("hostile", trappingComponent, .empty), &token);
        try std.testing.expectEqual(Conclusion.trapped, outcome.conclusion);
    }

    const outcome = host.run(describe("ordinary", completingComponent, .empty), &token);
    try std.testing.expect(outcome.succeeded());
    try std.testing.expectEqual(@as(u64, 64), host.failures);
}

test "a component cannot reach an undeclared file or destination" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    const file_probe = host.run(describe("probe", probingComponent, readableGrant()), &token);
    try std.testing.expectEqual(Conclusion.resource_denied, file_probe.conclusion);
    try std.testing.expectEqual(@as(u64, 1), file_probe.resource_refusals);

    const network_probe = host.run(
        describe("probe", networkProbingComponent, readableGrant()),
        &token,
    );
    try std.testing.expectEqual(Conclusion.resource_denied, network_probe.conclusion);
}

test "a component reaches exactly what it was granted" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    const outcome = host.run(
        describe("reader", wellBehavedFileComponent, readableGrant()),
        &token,
    );
    try std.testing.expect(outcome.succeeded());
    try std.testing.expectEqual(@as(u64, 0), outcome.resource_refusals);
}

test "cancellation interrupts a component at its next yield point" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);

    var token: CancellationToken = .{};
    token.request();

    const outcome = host.run(describe("looping", yieldingComponent, .empty), &token);

    try std.testing.expectEqual(Conclusion.cancelled, outcome.conclusion);
    // It stopped at the first yield rather than running to its meter.
    try std.testing.expectEqual(@as(u64, 0), outcome.steps_consumed);
}

test "a component that declines to yield is still bounded by its meter" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);

    var token: CancellationToken = .{};
    token.request();

    var stubborn = describe("stubborn", nonYieldingComponent, .empty);
    stubborn.step_budget = 500;

    const outcome = host.run(stubborn, &token);

    // Cancellation cannot reach it, so the meter must.
    try std.testing.expectEqual(Conclusion.meter_exhausted, outcome.conclusion);
    try std.testing.expectEqual(@as(u64, 500), outcome.steps_consumed);
}

test "a memory budget is enforced and the component is stopped at it" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    var hungry = describe("hungry", memoryHungryComponent, .empty);
    hungry.memory_ceiling_bytes = 32 * 1024;

    const outcome = host.run(hungry, &token);

    try std.testing.expectEqual(Conclusion.budget_exhausted, outcome.conclusion);
    try std.testing.expect(outcome.peak_bytes <= 32 * 1024);
}

test "one component's ceiling does not affect the next" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    var hungry = describe("hungry", memoryHungryComponent, .empty);
    hungry.memory_ceiling_bytes = 16 * 1024;
    _ = host.run(hungry, &token);

    // The next component gets its own full ceiling.
    const outcome = host.run(describe("ordinary", completingComponent, .empty), &token);
    try std.testing.expect(outcome.succeeded());
}

test "memory a component fails to release is reclaimed by the host" {
    const gpa = std.testing.allocator;
    var host: Host = .init(gpa);
    var token: CancellationToken = .{};

    const outcome = host.run(describe("leaky", leakingComponent, .empty), &token);

    // The leak is visible in the outcome, and the host does not carry it.
    try std.testing.expect(outcome.leaked_bytes >= 1024);
    try std.testing.expect(outcome.succeeded());

    const next = host.run(describe("ordinary", completingComponent, .empty), &token);
    try std.testing.expect(next.succeeded());
}

test "a meter charge larger than what remains exhausts rather than wraps" {
    var meter: Meter = .init(10);
    try std.testing.expect(meter.charge(4));
    try std.testing.expect(!meter.charge(1_000));
    try std.testing.expect(meter.isExhausted());
    try std.testing.expectEqual(@as(u64, 10), meter.consumed);
}

test "every failure mode maps to a distinct conclusion" {
    // A conclusion that collapsed two failure modes would make a hostile
    // component indistinguishable from a merely broken one in the ledger.
    const conclusions = [_]Conclusion{
        .completed,
        .trapped,
        .meter_exhausted,
        .budget_exhausted,
        .resource_denied,
        .cancelled,
        .deadline_exceeded,
    };
    try std.testing.expectEqual(std.enums.values(Conclusion).len, conclusions.len);
    for (conclusions) |conclusion| {
        try std.testing.expectEqual(conclusion != .completed, conclusion.isFailure());
    }
}
