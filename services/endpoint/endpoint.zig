//! The receive front end every trusted service runs: it takes a signed message,
//! puts it through the IPC pipeline, and — if it survives — dispatches it to a
//! handler under metering, cancellation, and transition journaling, returning a
//! typed reply or fault.
//!
//! The IPC layer's `pipeline.receive` decides that a message is authentic, is not a
//! replay, presents a capability that authorizes exactly the method it names, and
//! routes to a service. It stops there: nothing runs, nothing is charged, no state
//! changes. This endpoint is what a service wraps around that decision to actually
//! serve the call, and it adds the four things a running service needs that a pure
//! decision cannot provide. It meters: a call reserves its declared cost before it
//! runs and is refused as budget-exhausted if the service cannot afford it, so no
//! caller can make a service commit past its budget. It journals: a mutating call
//! records its intent before applying and commits after, so a restart in the middle
//! recovers rather than leaving half-applied state. It tracks cancellation: a call in
//! flight is registered so a cancel can reach it and the handler can stop
//! cooperatively. And it contains failure: a handler returns a fault rather than an
//! escaping error, so a bad request becomes a typed refusal, never a crash of the
//! service loop.
//!
//! The one containment this endpoint cannot provide is the one the supervisor does:
//! a handler that truly traps — corrupts memory, aborts the process — takes the
//! service's address space with it, and only a process boundary keeps that from
//! reaching the control plane. This endpoint contains faults; the supervisor
//! contains traps. Together they are the service isolation the platform promises.

const std = @import("std");
const ipc = @import("ipc");
const dispatch_module = @import("dispatch.zig");
const meter_module = @import("meter.zig");
const journal_module = @import("journal.zig");

pub const Envelope = ipc.envelope.Envelope;
pub const FaultCode = ipc.envelope.FaultCode;
pub const Reply = dispatch_module.Reply;
pub const Handler = dispatch_module.Handler;
pub const Call = dispatch_module.Call;
pub const Meter = meter_module.Meter;
pub const Journal = journal_module.Journal;
pub const Priority = meter_module.Priority;

/// How a service is configured: which methods it serves, how it routes, and the
/// bounds it runs within.
pub const Config = struct {
    /// This service's identifier, matched against the routing decision so a message
    /// routed elsewhere is never served here.
    service_id: ipc.routing.ServiceId,
    /// The routes this service owns. Every method maps to `service_id`; the pipeline
    /// resolves against it so an unrouted method is rejected before dispatch.
    routes: ipc.routing.Table,
    /// The handlers for the methods this service serves.
    handlers: []const Handler,
    /// The resource pool a call is metered against.
    capacity_units: u64,
    /// Units of the pool held back for system-priority callers.
    reserved_units: u64 = 0,
    /// The most calls that may be in flight at once, bounding the cancellation
    /// tracking so it cannot grow without limit.
    max_in_flight: usize = 64,
    /// The most transitions the journal holds in doubt at once.
    journal_capacity: usize = 1024,
};

/// A trusted service's receive path.
///
/// Ownership: the endpoint owns its meter, journal, and in-flight tracking. It
/// borrows the verifier and resolver — the pieces that hold identity and authority,
/// which the service's control plane sets up and may share. `deinit` releases only
/// what the endpoint owns.
pub const Endpoint = struct {
    gpa: std.mem.Allocator,
    service_id: ipc.routing.ServiceId,
    routes: ipc.routing.Table,
    handlers: dispatch_module.Table,
    /// Authenticates inbound messages. Borrowed: the control plane sets up which
    /// senders are trusted.
    verifier: *ipc.authenticator.Verifier,
    /// Turns a presented capability into its grant state. Borrowed from the
    /// capability service.
    resolver: ipc.pipeline.Resolver,
    meter: Meter,
    journal: Journal,
    /// Backing slots for calls in flight, reused across calls. A slot in a terminal
    /// state is free; a fresh call takes one.
    inflight: []ipc.cancellation.Request,

    pub fn init(
        gpa: std.mem.Allocator,
        verifier: *ipc.authenticator.Verifier,
        resolver: ipc.pipeline.Resolver,
        config: Config,
    ) !Endpoint {
        const inflight = try gpa.alloc(ipc.cancellation.Request, config.max_in_flight);
        errdefer gpa.free(inflight);
        // Every slot starts free: correlation zero and a terminal state, so the
        // first call that needs a slot may take any of them.
        for (inflight) |*slot| slot.* = .{ .correlation = 0, .principal = 0, .state = .done };

        var journal = Journal.init(gpa);
        journal.capacity = config.journal_capacity;

        return .{
            .gpa = gpa,
            .service_id = config.service_id,
            .routes = config.routes,
            .handlers = .{ .handlers = config.handlers },
            .verifier = verifier,
            .resolver = resolver,
            .meter = Meter.init(config.capacity_units, config.reserved_units),
            .journal = journal,
            .inflight = inflight,
        };
    }

    pub fn deinit(endpoint: *Endpoint) void {
        endpoint.journal.deinit();
        endpoint.gpa.free(endpoint.inflight);
        endpoint.* = undefined;
    }

    fn registry(endpoint: *Endpoint) ipc.cancellation.Registry {
        return .{ .requests = endpoint.inflight };
    }

    /// Registers a call as in flight, returning false if every slot is taken.
    ///
    /// A full in-flight table is backpressure, not an error: the service is already
    /// serving as many calls as it tracks, and admitting another it could not cancel
    /// would defeat the tracking. The caller turns a false into an `unavailable`
    /// fault.
    fn beginCall(endpoint: *Endpoint, env: Envelope) bool {
        for (endpoint.inflight) |*slot| {
            // A slot is free once its call has finished: `done` is cancellation's
            // only terminal state, so a slot in any other state is still in flight.
            if (slot.state != .done) continue;
            slot.* = .{
                .correlation = env.correlation,
                .principal = env.principal,
                .task = env.task,
                .deadline_nanoseconds = env.deadline_nanoseconds,
                .state = .active,
            };
            return true;
        }
        return false;
    }

    fn endCall(endpoint: *Endpoint, correlation: u64) void {
        endpoint.registry().complete(correlation);
    }

    /// Cancels an in-flight call by correlation, on the caller's authority. A cancel
    /// that arrives while a handler is between safe points is observed at its next
    /// `Call.stopped` check.
    pub fn cancel(endpoint: *Endpoint, correlation: u64, principal: u128) ipc.cancellation.Outcome {
        return endpoint.registry().cancel(.{ .correlation = correlation, .principal = principal });
    }

    /// Cancels every in-flight call belonging to a task, so a cancelled task's work
    /// stops together rather than leaving orphans.
    pub fn cancelTask(endpoint: *Endpoint, task: u128, principal: u128) usize {
        return endpoint.registry().cancelTask(task, principal);
    }

    /// Runs one signed message through the whole receive path and returns the reply.
    ///
    /// The pipeline decides authenticity, replay, authority, and routing; a failure
    /// at any of those becomes a typed fault here without ever reaching a handler.
    /// Only a message that passes is dispatched, under the metering, cancellation,
    /// and journaling `dispatch` applies. `priority` is the caller's class, which the
    /// meter uses to decide whether the call may draw on the system reserve; the
    /// control plane sets it from the authenticated sender, not from the message.
    pub fn serve(
        endpoint: *Endpoint,
        message: ipc.authenticator.SignedMessage,
        priority: Priority,
        now_ns: u64,
    ) Reply {
        const outcome = ipc.pipeline.receive(
            endpoint.verifier,
            message,
            endpoint.resolver,
            endpoint.routes,
            now_ns,
        );
        switch (outcome) {
            .fault => |fault| return .{ .fault = fault },
            .deliver => |delivery| {
                // A message routed to another service is never served here, even if
                // the pipeline delivered it: the endpoint answers only for itself.
                if (delivery.service != endpoint.service_id) return .{ .fault = .unavailable };
                return endpoint.dispatch(delivery.envelope, priority, now_ns);
            },
        }
    }

    /// Dispatches an already-authenticated, authorized, routed request to its
    /// handler under metering, cancellation, and journaling.
    ///
    /// The order is deliberate. The method is resolved to a handler first, so an
    /// unhandled method costs nothing. The call is then charged; a call the service
    /// cannot afford is refused before it runs. It is registered as in flight so a
    /// cancel can reach it and its deadline is checked. A mutating call records its
    /// intent before the handler runs and commits after it succeeds — or aborts if
    /// the handler fails cleanly, since a failed mutation did not happen. Whatever
    /// the outcome, the reservation is released and the call is marked complete, so a
    /// reply never leaks budget or an in-flight slot.
    pub fn dispatch(endpoint: *Endpoint, env: Envelope, priority: Priority, now_ns: u64) Reply {
        const handler = endpoint.handlers.find(env.method) orelse return .{ .fault = .unsupported };

        const charge = endpoint.meter.charge(priority, handler.cost_units);
        if (!charge.ok()) return .{ .fault = .budget_exhausted };
        const reservation = charge.admitted;
        defer endpoint.meter.release(reservation);

        if (!endpoint.beginCall(env)) return .{ .fault = .unavailable };
        defer endpoint.endCall(env.correlation);

        // A call already past its deadline is not started: the work is no longer
        // worth doing, and the handler would only observe the same thing.
        if (env.deadline_nanoseconds != 0 and @as(i64, @intCast(now_ns)) >= env.deadline_nanoseconds) {
            return .{ .fault = .deadline_exceeded };
        }

        const journaled = handler.mutates();
        if (journaled) {
            // If the intent cannot even be recorded, the mutation must not run: a
            // mutation the journal did not see could not be recovered after a crash.
            endpoint.journal.prepare(env.correlation, env.idempotency_key, env.method) catch {
                return .{ .fault = .unavailable };
            };
        }

        var live_registry = endpoint.registry();
        const call: Call = .{
            .envelope = env,
            .now_ns = @intCast(now_ns),
            .cancels = &live_registry,
        };
        const reply = handler.serve(handler.context, call);

        if (journaled) {
            switch (reply) {
                // The effect is durably applied: commit, so a restart leaves it be.
                .ok => endpoint.journal.commit(env.correlation),
                // The handler refused; the effect did not happen. Drop the intent so
                // recovery does not re-drive a transition that never applied.
                .fault => endpoint.journal.abort(env.correlation),
            }
        }

        return reply;
    }
};

// --- Tests ---

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

const holder: u128 = 0xAA;
const service_capability: u128 = 0x55;

/// A resolver that hands out one fixed grant for one capability id.
const GrantBox = struct {
    grant: ?ipc.capability_binding.Grant,

    fn lookup(context: *anyopaque, capability: u128) ?ipc.capability_binding.Grant {
        const box: *GrantBox = @ptrCast(@alignCast(context));
        if (capability != service_capability) return null;
        return box.grant;
    }

    fn resolver(box: *GrantBox) ipc.pipeline.Resolver {
        return .{ .context = box, .lookup = lookup };
    }
};

/// A handler that counts its calls and can be told to fail or to do cancellable
/// work, so the endpoint's wrapping can be observed without a real service.
const Probe = struct {
    calls: u32 = 0,
    fail: bool = false,
    observed_cancel: bool = false,
    reply_bytes: []const u8 = "served",

    fn read(context: *anyopaque, _: Call) Reply {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail) return .{ .fault = .invalid_input };
        return .{ .ok = self.reply_bytes };
    }

    fn write(context: *anyopaque, _: Call) Reply {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail) return .{ .fault = .conflict };
        return .{ .ok = self.reply_bytes };
    }

    fn cancellableWork(context: *anyopaque, call: Call) Reply {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.calls += 1;
        // A real handler checks between steps; this one checks once.
        if (call.stopped()) {
            self.observed_cancel = true;
            return .{ .fault = .cancelled };
        }
        return .{ .ok = self.reply_bytes };
    }
};

const service_id: ipc.routing.ServiceId = 7;

const test_routes = [_]ipc.routing.Route{
    .{ .method = "probe.read", .service = service_id },
    .{ .method = "probe.write", .service = service_id },
    .{ .method = "probe.work", .service = service_id },
};

fn handlersFor(probe: *Probe) [3]Handler {
    return .{
        .{ .method = "probe.read", .required_capability = "probe.read", .effect = .read_only, .cost_units = 10, .context = probe, .serve = Probe.read },
        .{ .method = "probe.write", .required_capability = "probe.write", .effect = .local_mutation, .cost_units = 10, .context = probe, .serve = Probe.write },
        .{ .method = "probe.work", .required_capability = "probe.work", .effect = .read_only, .cost_units = 10, .context = probe, .serve = Probe.cancellableWork },
    };
}

fn signerFor(seed: u8) ipc.authenticator.SigningIdentity {
    return .{ .service = holder, .key_pair = Ed25519.KeyPair.generateDeterministic(@splat(seed)) catch unreachable };
}

/// Encodes and signs a request for a method, returning owned body bytes the caller
/// must free.
fn signedRequest(
    gpa: std.mem.Allocator,
    signer: ipc.authenticator.SigningIdentity,
    method: []const u8,
    correlation: u64,
    idempotency_key: u128,
    deadline: i64,
) !ipc.authenticator.SignedMessage {
    const message: Envelope = .{
        .version = .{ .major = 1, .minor = 0 },
        .kind = .request,
        .correlation = correlation,
        .idempotency_key = idempotency_key,
        .principal = holder,
        .task = 0,
        .capability = service_capability,
        .deadline_nanoseconds = deadline,
        .method = method,
        .fault = null,
        .payload = "",
    };
    const body = try gpa.alloc(u8, message.encodedSize());
    errdefer gpa.free(body);
    _ = try ipc.envelope.encode(message, body);
    return ipc.authenticator.sign(signer, body);
}

const Harness = struct {
    verifier: ipc.authenticator.Verifier,
    box: GrantBox,
    endpoint: Endpoint,
    probe: *Probe,
    signer: ipc.authenticator.SigningIdentity,
    handlers: [3]Handler,

    fn init(gpa: std.mem.Allocator, probe: *Probe, harness: *Harness, capacity: u64) !void {
        harness.signer = signerFor(1);
        harness.verifier = ipc.authenticator.Verifier.init(gpa);
        try harness.verifier.trust(holder, harness.signer.publicKey());
        harness.box = .{ .grant = .{
            .bound_principal = holder,
            .scopes = &.{.{ .pattern = "probe.", .prefix = true }},
        } };
        harness.probe = probe;
        harness.handlers = handlersFor(probe);
        harness.endpoint = try Endpoint.init(gpa, &harness.verifier, harness.box.resolver(), .{
            .service_id = service_id,
            .routes = .{ .routes = &test_routes },
            .handlers = &harness.handlers,
            .capacity_units = capacity,
        });
    }

    fn deinit(harness: *Harness) void {
        harness.endpoint.deinit();
        harness.verifier.deinit();
    }
};

test "a signed, authorized, routed request reaches its handler and replies" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    const signed = try signedRequest(gpa, harness.signer, "probe.read", 1, 100, 0);
    defer gpa.free(signed.body);

    const reply = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expect(reply.succeeded());
    try testing.expectEqualStrings("served", reply.ok);
    try testing.expectEqual(@as(u32, 1), probe.calls);
    // The call released its reservation and its in-flight slot.
    try testing.expect(harness.endpoint.meter.isBalanced());
}

test "a request whose capability does not cover the method is refused before the handler" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();
    // Narrow the grant so it no longer covers probe.*
    harness.box.grant = .{ .bound_principal = holder, .scopes = &.{.{ .pattern = "other.", .prefix = true }} };

    const signed = try signedRequest(gpa, harness.signer, "probe.read", 1, 100, 0);
    defer gpa.free(signed.body);

    const reply = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expectEqual(FaultCode.unauthorized, reply.fault);
    try testing.expectEqual(@as(u32, 0), probe.calls); // never dispatched
}

test "a message signed by an untrusted key is an integrity fault, not a crash" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    const signed = try signedRequest(gpa, signerFor(2), "probe.read", 1, 100, 0);
    defer gpa.free(signed.body);

    const reply = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expectEqual(FaultCode.integrity_failure, reply.fault);
}

test "a call the service cannot afford is refused as budget exhausted before it runs" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    // Capacity 10 fits exactly one 10-unit call; a second concurrent one would not,
    // but calls here are synchronous, so shrink capacity below one call's cost.
    try Harness.init(gpa, &probe, &harness, 5);
    defer harness.deinit();

    const signed = try signedRequest(gpa, harness.signer, "probe.read", 1, 100, 0);
    defer gpa.free(signed.body);

    const reply = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expectEqual(FaultCode.budget_exhausted, reply.fault);
    try testing.expectEqual(@as(u32, 0), probe.calls); // never ran
    try testing.expect(harness.endpoint.meter.isBalanced());
}

test "a request past its deadline is refused without running the handler" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    // Deadline 100; now 200.
    const signed = try signedRequest(gpa, harness.signer, "probe.read", 1, 100, 100);
    defer gpa.free(signed.body);

    const reply = harness.endpoint.serve(signed, .ordinary, 200);
    try testing.expectEqual(FaultCode.deadline_exceeded, reply.fault);
    try testing.expectEqual(@as(u32, 0), probe.calls);
}

test "a mutating call that succeeds commits its transition" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    const signed = try signedRequest(gpa, harness.signer, "probe.write", 1, 0xBEEF, 0);
    defer gpa.free(signed.body);

    const reply = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expect(reply.succeeded());
    try testing.expectEqual(journal_module.Phase.committed, harness.endpoint.journal.phaseOf(1).?);
    try testing.expect(!harness.endpoint.journal.hasInDoubt());
}

test "a mutating call that fails cleanly aborts its transition, leaving nothing in doubt" {
    const gpa = testing.allocator;
    var probe: Probe = .{ .fail = true };
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    const signed = try signedRequest(gpa, harness.signer, "probe.write", 1, 0xBEEF, 0);
    defer gpa.free(signed.body);

    const reply = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expectEqual(FaultCode.conflict, reply.fault);
    // The failed mutation left no transition to recover.
    try testing.expect(harness.endpoint.journal.phaseOf(1) == null);
    try testing.expect(!harness.endpoint.journal.hasInDoubt());
}

test "a cancelled in-flight call is observed by its handler and stops" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    // Pre-register the call as in flight and cancel it, so the handler observes the
    // cancellation at its safe point during dispatch.
    const env: Envelope = .{
        .version = .{ .major = 1, .minor = 0 },
        .kind = .request,
        .correlation = 42,
        .idempotency_key = 0,
        .principal = holder,
        .task = 0,
        .capability = service_capability,
        .deadline_nanoseconds = 0,
        .method = "probe.work",
        .fault = null,
        .payload = "",
    };
    try testing.expect(harness.endpoint.beginCall(env));
    try testing.expectEqual(ipc.cancellation.Outcome.marked, harness.endpoint.cancel(42, holder));

    const reply = harness.endpoint.dispatch(env, .ordinary, 0);
    try testing.expectEqual(FaultCode.cancelled, reply.fault);
    try testing.expect(probe.observed_cancel);
}

test "an unhandled method is unsupported and costs nothing" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    const env: Envelope = .{
        .version = .{ .major = 1, .minor = 0 },
        .kind = .request,
        .correlation = 1,
        .idempotency_key = 0,
        .principal = holder,
        .task = 0,
        .capability = service_capability,
        .deadline_nanoseconds = 0,
        .method = "probe.absent",
        .fault = null,
        .payload = "",
    };
    const reply = harness.endpoint.dispatch(env, .ordinary, 0);
    try testing.expectEqual(FaultCode.unsupported, reply.fault);
    try testing.expect(harness.endpoint.meter.isBalanced());
}

test "a replayed mutating request is refused the second time by the verifier" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    var harness: Harness = undefined;
    try Harness.init(gpa, &probe, &harness, 1000);
    defer harness.deinit();

    const signed = try signedRequest(gpa, harness.signer, "probe.write", 1, 0xBEEF, 0);
    defer gpa.free(signed.body);

    const first = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expect(first.succeeded());
    // The identical signed message again is a replay, refused as a conflict.
    const second = harness.endpoint.serve(signed, .ordinary, 0);
    try testing.expectEqual(FaultCode.conflict, second.fault);
    try testing.expectEqual(@as(u32, 1), probe.calls); // the handler ran only once
}
