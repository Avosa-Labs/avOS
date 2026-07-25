//! The services layer's acceptance criteria, exercised end to end against the real
//! service front ends rather than any one module's unit tests.
//!
//! Track 3 asks for five properties, and each is a test here. A malicious or
//! malformed request is contained as a typed fault and the service keeps serving. A
//! caller cannot invoke a method its capability does not cover — the confinement that
//! keeps a component off any surface it was not granted. An over-budget call is
//! refused and the service survives it. A cancelled call stops and leaves the service
//! balanced. And a state transition left in doubt by a restart recovers to exactly one
//! clean effect, never a half-applied or doubled one. The trap-containment property —
//! that a service that truly crashes does not take the control plane with it — is the
//! supervisor's, proven in its own process-level tests; here we prove the fault
//! containment that sits above it.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const journal_module = @import("../endpoint/journal.zig");
const payload = @import("../endpoint/payload.zig");
const harness = @import("../endpoint/harness.zig");
const capability = @import("../capability/service.zig");

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

fn testSigner() ipc.authenticator.SigningIdentity {
    return .{ .service = harness.caller, .key_pair = Ed25519.KeyPair.generateDeterministic(@splat(9)) catch unreachable };
}

const Setup = struct {
    service: capability.Service,
    storage: [4]dispatch.Handler,
    fixture: harness.Fixture,

    fn init(gpa: std.mem.Allocator, setup: *Setup) !void {
        setup.service = capability.Service.init(gpa);
        setup.storage = setup.service.handlers();
        try harness.Fixture.init(gpa, &setup.fixture, .{
            .service_id = capability.service_id,
            .routes = .{ .routes = &capability.routes },
            .handlers = &setup.storage,
            .prefix = "capability.",
            .signer = testSigner(),
        });
    }

    fn deinit(setup: *Setup) void {
        setup.fixture.deinit();
        setup.service.deinit();
    }
};

fn issueBody(buffer: []u8, holder: u128, scope_bits: u8, delegatable: bool, depth: u8) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU128(holder) catch unreachable;
    writer.putU8(scope_bits) catch unreachable;
    writer.putBool(delegatable) catch unreachable;
    writer.putU8(depth) catch unreachable;
    return writer.written();
}

test "a malformed request is contained as a fault and the service keeps serving" {
    const gpa = testing.allocator;
    var setup: Setup = undefined;
    try Setup.init(gpa, &setup);
    defer setup.deinit();

    // A truncated issue payload must be refused as invalid input, not crash.
    const bad = try setup.fixture.call("capability.issue", 1, 0x1, &[_]u8{ 1, 2, 3 });
    try testing.expectEqual(endpoint.FaultCode.invalid_input, bad.fault);

    // The service is unharmed: a well-formed request immediately after succeeds.
    var buffer: [32]u8 = undefined;
    const good = try setup.fixture.call("capability.issue", 2, 0x2, issueBody(&buffer, harness.caller, 0b0001, true, 1));
    try testing.expect(good.succeeded());
}

test "a caller cannot invoke a method its capability does not cover" {
    const gpa = testing.allocator;
    var setup: Setup = undefined;
    try Setup.init(gpa, &setup);
    defer setup.deinit();

    // Narrow the caller's grant so it no longer covers any capability.* method — the
    // stand-in for a component reaching a surface it was never declared for.
    setup.fixture.grant.scopes[0] = .{ .pattern = "unrelated.", .prefix = true };

    var buffer: [32]u8 = undefined;
    const refused = try setup.fixture.call("capability.issue", 1, 0x1, issueBody(&buffer, harness.caller, 0b0001, true, 1));
    try testing.expectEqual(endpoint.FaultCode.unauthorized, refused.fault);
    try testing.expectEqual(@as(usize, 0), setup.service.records.items.len); // nothing happened
}

test "an over-budget call is refused and the service survives it" {
    const gpa = testing.allocator;
    var setup: capability.Service = capability.Service.init(gpa);
    defer setup.deinit();
    var storage = setup.handlers();
    var fixture: harness.Fixture = undefined;
    // A pool too small for even one issue (cost 4).
    try harness.Fixture.init(gpa, &fixture, .{
        .service_id = capability.service_id,
        .routes = .{ .routes = &capability.routes },
        .handlers = &storage,
        .prefix = "capability.",
        .signer = testSigner(),
        .capacity_units = 2,
    });
    defer fixture.deinit();

    var buffer: [32]u8 = undefined;
    const refused = try fixture.call("capability.issue", 1, 0x1, issueBody(&buffer, harness.caller, 0b0001, true, 1));
    try testing.expectEqual(endpoint.FaultCode.budget_exhausted, refused.fault);
    // The endpoint released nothing it did not reserve; it is balanced and operable.
    try testing.expect(fixture.ep.meter.isBalanced());
}

test "a call whose deadline has passed stops before running and stays balanced" {
    // The deadline-driven half of cooperative stopping; the explicit-cancel half —
    // a cancel reaching a handler mid-call — is proven in the endpoint's own tests.
    const gpa = testing.allocator;
    var setup: Setup = undefined;
    try Setup.init(gpa, &setup);
    defer setup.deinit();

    var buffer: [16]u8 = undefined;
    var id_writer = payload.Writer.init(&buffer);
    try id_writer.putU128(1);

    // Dispatched at now=200 with a deadline of 100: the work is no longer worth doing
    // and the call stops before the handler runs.
    const reply = setup.fixture.ep.dispatch(.{
        .version = .{ .major = 1, .minor = 0 },
        .kind = .request,
        .correlation = 55,
        .idempotency_key = 0,
        .principal = harness.caller,
        .task = 0,
        .capability = 0x1,
        .deadline_nanoseconds = 100,
        .method = "capability.describe",
        .fault = null,
        .payload = id_writer.written(),
    }, .system, 200);
    try testing.expectEqual(endpoint.FaultCode.deadline_exceeded, reply.fault);
    try testing.expect(setup.fixture.ep.meter.isBalanced());
}

test "a transition in doubt after a restart recovers to exactly one clean effect" {
    const gpa = testing.allocator;
    var setup: Setup = undefined;
    try Setup.init(gpa, &setup);
    defer setup.deinit();

    var buffer: [32]u8 = undefined;
    const body = issueBody(&buffer, harness.caller, 0b0001, true, 1);
    const key: u128 = 0xABCD;

    // Before the "crash", the intent to issue was journaled but the effect was never
    // confirmed committed — the classic in-doubt transition a restart must resolve.
    var wal = journal_module.Journal.init(gpa);
    defer wal.deinit();
    try wal.prepare(1, key, "capability.issue");
    try testing.expect(wal.hasInDoubt());

    // Recovery re-drives the transition against the service, keyed so applying it —
    // even more than once — yields a single capability.
    const Redriver = struct {
        fixture: *harness.Fixture,
        body: []const u8,
        next_correlation: u64 = 100,
        fn redrive(context: *anyopaque, transition: journal_module.Transition) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.next_correlation += 1;
            const reply = self.fixture.redrive("capability.issue", self.next_correlation, transition.idempotency_key, self.body);
            return reply.succeeded();
        }
    };
    var redriver: Redriver = .{ .fixture = &setup.fixture, .body = body };

    const remaining_first = wal.recover(.{ .context = &redriver, .redrive = Redriver.redrive });
    try testing.expectEqual(@as(usize, 0), remaining_first);
    try testing.expect(!wal.hasInDoubt());
    try testing.expectEqual(@as(usize, 1), setup.service.records.items.len);

    // A second recovery pass — as if the restart itself was interrupted and re-run —
    // finds the transition already committed, re-drives nothing, and still leaves
    // exactly one capability: recovery is idempotent.
    const remaining_second = wal.recover(.{ .context = &redriver, .redrive = Redriver.redrive });
    try testing.expectEqual(@as(usize, 0), remaining_second);
    try testing.expectEqual(@as(usize, 1), setup.service.records.items.len);
}
