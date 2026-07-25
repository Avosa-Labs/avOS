//! The runtimes layer's headline acceptance property, exercised against the one
//! boundary all four runtimes share: an unauthorized host-capability request is
//! denied at the boundary, the same way, whoever makes it.
//!
//! Each runtime shapes a host request in its own idiom — a native filesystem open, a
//! wasm host import, an Android intent, a web bridge call — but all of them reach the
//! host through the same capability bridge, and the point of that single boundary is
//! that authorization does not depend on which idiom was used. This test presents the
//! four runtime-shaped requests to one bridge and asserts the two invariants that
//! matter: a request backed by a matching capability is allowed, and one that is not
//! is denied — uniformly, and counted, so a runtime reaching for authority it lacks is
//! visible rather than quietly succeeding in one adapter and failing in another.

const std = @import("std");
const core = @import("core");
const host_bridge = @import("host_capability.zig");

const capability = core.capability;
const identity = core.identity;
const time = core.time;
const principal_model = core.principal;

const testing = std.testing;

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal_model.Registry,
    store: capability.Store,
    operator: identity.PrincipalId,
    guest: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        fixture.* = .{
            .ids = .initDeterministic(4242),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .operator = .none,
            .guest = .none,
        };
        fixture.registry = .init(gpa, &fixture.ids, fixture.manual.clock());
        fixture.store = .init(gpa, &fixture.ids, fixture.manual.clock(), &fixture.registry);
        fixture.operator = try fixture.registry.enroll(.{ .kind = .human, .display_name = "operator", .policy_domain = "local" });
        fixture.guest = try fixture.registry.enroll(.{ .kind = .agent, .display_name = "guest", .policy_domain = "local", .expires_at = .fromSeconds(100_000), .issuer = fixture.operator });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    fn grant(fixture: *Fixture, kind: []const u8, operation: capability.Operation) !capability.Handle {
        var operations: capability.OperationSet = .initEmpty();
        operations.insert(operation);
        return fixture.store.issue(.{
            .issuer = fixture.operator,
            .holder = fixture.guest,
            .resource = .{ .kind = kind },
            .operations = operations,
        });
    }
};

/// The four runtime idioms, each reduced to the host request it makes: the operation
/// and the resource kind it needs. One boundary decides all of them.
const RuntimeRequest = struct {
    runtime: []const u8,
    operation: capability.Operation,
    resource_kind: []const u8,
};

const runtime_requests = [_]RuntimeRequest{
    .{ .runtime = "native", .operation = .read, .resource_kind = "filesystem" },
    .{ .runtime = "wasm", .operation = .write, .resource_kind = "storage" },
    .{ .runtime = "android", .operation = .read, .resource_kind = "location" },
    .{ .runtime = "web", .operation = .read, .resource_kind = "files" },
};

test "an unauthorized host request is denied at the boundary for every runtime" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A capability for one unrelated resource. No runtime's request is for it.
    const unrelated = try fixture.grant("calendar", .read);
    var bridge = host_bridge.Bridge.init(&fixture.store);

    for (runtime_requests) |request| {
        const decision = bridge.cross(.{
            .holder = fixture.guest,
            .handle = unrelated,
            .operation = request.operation,
            .resource_kind = request.resource_kind,
        });
        // Whatever the runtime idiom, an unbacked request is denied here.
        try testing.expect(!decision.allowed());
    }
    // Every runtime's crossing was seen and every one denied — one boundary, one rule.
    try testing.expectEqual(@as(u64, runtime_requests.len), bridge.crossings);
    try testing.expectEqual(@as(u64, runtime_requests.len), bridge.denials);
}

test "an authorized host request is allowed at the boundary regardless of runtime" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var bridge = host_bridge.Bridge.init(&fixture.store);
    for (runtime_requests) |request| {
        // Grant exactly what this runtime's request needs, then make it.
        const handle = try fixture.grant(request.resource_kind, request.operation);
        const decision = bridge.cross(.{
            .holder = fixture.guest,
            .handle = handle,
            .operation = request.operation,
            .resource_kind = request.resource_kind,
        });
        try testing.expect(decision.allowed());
    }
    // Every crossing was authorized; none denied.
    try testing.expectEqual(@as(u64, 0), bridge.denials);
}

test "a guest cannot widen a narrow grant by crossing repeatedly" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // Read on filesystem, nothing more.
    const handle = try fixture.grant("filesystem", .read);
    var bridge = host_bridge.Bridge.init(&fixture.store);

    // Reading is allowed every time; writing is denied every time. Repetition does
    // not turn a read grant into a write one.
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        try testing.expect(bridge.cross(.{ .holder = fixture.guest, .handle = handle, .operation = .read, .resource_kind = "filesystem" }).allowed());
        try testing.expect(!bridge.cross(.{ .holder = fixture.guest, .handle = handle, .operation = .write, .resource_kind = "filesystem" }).allowed());
    }
}
