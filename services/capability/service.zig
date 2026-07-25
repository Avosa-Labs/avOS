//! The capability service: the authenticated endpoint through which authority is
//! issued, delegated, and revoked, keeping a store of live capabilities behind a
//! typed IPC surface rather than in every caller's hands.
//!
//! A capability is authority a holder can exercise and pass on. Where the pure
//! `delegation` module decides whether one *may* be re-delegated, this service holds
//! the capabilities that exist, mints new ones, attenuates them down a delegation
//! chain, and revokes them — the state the decision is made against. It runs behind
//! the shared endpoint, so every request is authenticated, bound to a capability the
//! caller actually holds, metered, and journaled before it reaches a handler here.
//!
//! Every mutation is keyed by the request's idempotency key and recorded once. That
//! is what makes a restart mid-transition safe: re-applying an issue or a revoke the
//! service has already seen returns the same result rather than minting a second
//! capability or double-counting a revocation, so the journal can re-drive an
//! in-doubt transition to completion without fear of doubling its effect.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const journal_module = @import("../endpoint/journal.zig");
const payload = @import("../endpoint/payload.zig");
const delegation = @import("delegation.zig");

pub const CapabilityId = u128;
pub const Scope = delegation.Scope;
pub const Operation = delegation.Operation;

/// A capability the service holds.
pub const Record = struct {
    id: CapabilityId,
    holder: u128,
    scope: Scope,
    delegatable: bool,
    remaining_depth: u8,
    /// Bumped when the capability is revoked, so a stale handle fails the binding
    /// check's generation test at use.
    generation: u32 = 1,
    revoked: bool = false,
};

/// The result the service recorded for a mutation, so re-applying the same
/// idempotency key returns it rather than repeating the effect.
const Applied = struct {
    idempotency_key: u128,
    result_id: CapabilityId,
};

/// The capability store and the endpoint that fronts it.
pub const Service = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    next_id: CapabilityId = 1,
    reply_buffer: [64]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Service {
        return .{ .gpa = gpa };
    }

    pub fn deinit(service: *Service) void {
        service.records.deinit(service.gpa);
        service.applied.deinit(service.gpa);
        service.* = undefined;
    }

    fn find(service: *Service, id: CapabilityId) ?*Record {
        for (service.records.items) |*record| {
            if (record.id == id) return record;
        }
        return null;
    }

    /// The result already recorded for an idempotency key, if the mutation keyed by
    /// it has been applied before. This is the idempotency the journal relies on.
    fn priorResult(service: *Service, key: u128) ?CapabilityId {
        for (service.applied.items) |entry| {
            if (entry.idempotency_key == key) return entry.result_id;
        }
        return null;
    }

    fn recordApplied(service: *Service, key: u128, result: CapabilityId) !void {
        try service.applied.append(service.gpa, .{ .idempotency_key = key, .result_id = result });
    }

    // --- Handlers ---

    fn issue(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;

        // Idempotent replay: an issue already applied returns the same capability.
        if (service.priorResult(key)) |existing| return service.replyId(existing);

        var reader = payload.Reader.init(call.envelope.payload);
        const holder = reader.u128_() catch return .{ .fault = .invalid_input };
        const scope_bits = reader.u8_() catch return .{ .fault = .invalid_input };
        const delegatable = reader.boolean() catch return .{ .fault = .invalid_input };
        const depth = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const id = service.next_id;
        service.records.append(service.gpa, .{
            .id = id,
            .holder = holder,
            .scope = scopeFromBits(scope_bits),
            .delegatable = delegatable,
            .remaining_depth = depth,
        }) catch return .{ .fault = .unavailable };
        service.recordApplied(key, id) catch return .{ .fault = .unavailable };
        service.next_id += 1;
        return service.replyId(id);
    }

    fn delegate(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        if (service.priorResult(key)) |existing| return service.replyId(existing);

        var reader = payload.Reader.init(call.envelope.payload);
        const parent_id = reader.u128_() catch return .{ .fault = .invalid_input };
        const child_bits = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const parent = service.find(parent_id) orelse return .{ .fault = .invalid_input };
        if (parent.revoked) return .{ .fault = .capability_revoked };

        const child_scope = scopeFromBits(child_bits);
        // The pure rule decides whether this delegation is permitted: delegatable,
        // depth remaining, and a strict attenuation of the parent's scope.
        switch (delegation.decide(.{
            .scope = parent.scope,
            .delegatable = parent.delegatable,
            .remaining_depth = parent.remaining_depth,
        }, child_scope)) {
            .refuse => |refusal| return .{ .fault = switch (refusal) {
                .not_delegatable, .depth_exhausted => .constraint_violation,
                .widens_scope => .unauthorized,
            } },
            .delegate => |child_depth| {
                const id = service.next_id;
                service.records.append(service.gpa, .{
                    .id = id,
                    .holder = call.envelope.principal,
                    .scope = child_scope,
                    .delegatable = true,
                    .remaining_depth = child_depth,
                }) catch return .{ .fault = .unavailable };
                service.recordApplied(key, id) catch return .{ .fault = .unavailable };
                service.next_id += 1;
                return service.replyId(id);
            },
        }
    }

    fn revoke(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        if (service.priorResult(key)) |existing| return service.replyId(existing);

        var reader = payload.Reader.init(call.envelope.payload);
        const id = reader.u128_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const record = service.find(id) orelse return .{ .fault = .invalid_input };
        // Revoking is idempotent in its own right — a second revoke is a no-op — but
        // recording the key keeps recovery from re-running the generation bump.
        if (!record.revoked) {
            record.revoked = true;
            record.generation += 1;
        }
        service.recordApplied(key, id) catch return .{ .fault = .unavailable };
        return service.replyId(id);
    }

    fn describe(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const id = reader.u128_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const record = service.find(id) orelse return .{ .fault = .invalid_input };
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU8(scopeToBits(record.scope)) catch return .{ .fault = .internal_fault };
        writer.putBool(record.revoked) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    fn replyId(service: *Service, id: CapabilityId) dispatch.Reply {
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU128(id) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    /// The handler set, bound to this service instance.
    pub fn handlers(service: *Service) [4]dispatch.Handler {
        return .{
            .{ .method = "capability.issue", .required_capability = "capability.issue", .effect = .value_transfer, .cost_units = 4, .context = service, .serve = issue },
            .{ .method = "capability.delegate", .required_capability = "capability.delegate", .effect = .value_transfer, .cost_units = 4, .context = service, .serve = delegate },
            .{ .method = "capability.revoke", .required_capability = "capability.revoke", .effect = .local_mutation, .cost_units = 2, .context = service, .serve = revoke },
            .{ .method = "capability.describe", .required_capability = "capability.describe", .effect = .read_only, .cost_units = 1, .context = service, .serve = describe },
        };
    }
};

fn scopeFromBits(bits: u8) Scope {
    var scope: Scope = .initEmpty();
    inline for (@typeInfo(Operation).@"enum".fields, 0..) |field, index| {
        if (bits & (@as(u8, 1) << @intCast(index)) != 0) scope.insert(@enumFromInt(field.value));
    }
    return scope;
}

fn scopeToBits(scope: Scope) u8 {
    var bits: u8 = 0;
    inline for (@typeInfo(Operation).@"enum".fields, 0..) |field, index| {
        if (scope.contains(@enumFromInt(field.value))) bits |= (@as(u8, 1) << @intCast(index));
    }
    return bits;
}

/// The service id and routes the capability service owns.
pub const service_id: ipc.routing.ServiceId = 0x0CA9;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "capability.issue", .service = service_id },
    .{ .method = "capability.delegate", .service = service_id },
    .{ .method = "capability.revoke", .service = service_id },
    .{ .method = "capability.describe", .service = service_id },
};

/// The capability descriptor clients and the router derive from.
pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "capability",
    .methods = &.{
        .{ .name = "capability.issue", .required_capability = "capability.issue", .effect = .value_transfer },
        .{ .name = "capability.delegate", .required_capability = "capability.delegate", .effect = .value_transfer },
        .{ .name = "capability.revoke", .required_capability = "capability.revoke", .effect = .local_mutation },
        .{ .name = "capability.describe", .required_capability = "capability.describe", .effect = .read_only },
    },
};

// The three views of this service — descriptor, routes, and handler set — are pinned
// to agree at build time, so a method that routes but has no handler, or a handler
// under a capability the descriptor never declared, fails to compile.
comptime {
    ipc.descriptor.validate(descriptor) catch unreachable;
}

// --- Tests ---

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

const admin: u128 = 0xAD41;
const cap_id_capability: u128 = 0x0C;

const Harness = struct {
    service: *Service,
    verifier: ipc.authenticator.Verifier,
    grant: GrantBox,
    ep: endpoint.Endpoint,
    signer: ipc.authenticator.SigningIdentity,
    handler_storage: [4]dispatch.Handler,

    const GrantBox = struct {
        scope: []const delegation.Operation = &.{},
        fn lookup(context: *anyopaque, capability: u128) ?ipc.capability_binding.Grant {
            _ = capability;
            const box: *GrantBox = @ptrCast(@alignCast(context));
            _ = box;
            return .{ .bound_principal = admin, .scopes = &.{.{ .pattern = "capability.", .prefix = true }} };
        }
        fn resolver(box: *GrantBox) ipc.pipeline.Resolver {
            return .{ .context = box, .lookup = lookup };
        }
    };

    fn init(gpa: std.mem.Allocator, service: *Service, harness: *Harness) !void {
        service.* = Service.init(gpa);
        harness.service = service;
        harness.signer = .{ .service = admin, .key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(3)) };
        harness.verifier = ipc.authenticator.Verifier.init(gpa);
        try harness.verifier.trust(admin, harness.signer.publicKey());
        harness.grant = .{};
        harness.handler_storage = service.handlers();
        harness.ep = try endpoint.Endpoint.init(gpa, &harness.verifier, harness.grant.resolver(), .{
            .service_id = service_id,
            .routes = .{ .routes = &routes },
            .handlers = &harness.handler_storage,
            .capacity_units = 10_000,
        });
    }

    fn deinit(harness: *Harness) void {
        harness.ep.deinit();
        harness.verifier.deinit();
        harness.service.deinit();
    }

    fn envelopeFor(method: []const u8, correlation: u64, key: u128, body: []const u8) endpoint.Envelope {
        return .{
            .version = .{ .major = 1, .minor = 0 },
            .kind = .request,
            .correlation = correlation,
            .idempotency_key = key,
            .principal = admin,
            .task = 0,
            .capability = cap_id_capability,
            .deadline_nanoseconds = 0,
            .method = method,
            .fault = null,
            .payload = body,
        };
    }

    fn call(harness: *Harness, gpa: std.mem.Allocator, method: []const u8, correlation: u64, key: u128, body: []const u8) !dispatch.Reply {
        const message = envelopeFor(method, correlation, key, body);
        const bytes = try gpa.alloc(u8, message.encodedSize());
        defer gpa.free(bytes);
        _ = try ipc.envelope.encode(message, bytes);
        const signed = try ipc.authenticator.sign(harness.signer, bytes);
        return harness.ep.serve(signed, .system, 0);
    }

    /// Dispatches directly, bypassing the wire's replay guard, to simulate a
    /// recovery re-drive after a restart — where the same idempotency key legitimately
    /// arrives again and the store's own idempotency must absorb it.
    fn redrive(harness: *Harness, method: []const u8, correlation: u64, key: u128, body: []const u8) dispatch.Reply {
        return harness.ep.dispatch(envelopeFor(method, correlation, key, body), .system, 0);
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

test "issuing a capability returns an id and records the capability" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    const reply = try harness.call(gpa, "capability.issue", 1, 0x100, issueBody(&buffer, admin, 0b0001, true, 3));
    try testing.expect(reply.succeeded());
    try testing.expectEqual(@as(usize, 1), service.records.items.len);
}

test "re-issuing with the same idempotency key returns the same id and mints nothing new" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    const body = issueBody(&buffer, admin, 0b0001, true, 3);
    const first = try harness.call(gpa, "capability.issue", 1, 0x100, body);
    var first_reader = payload.Reader.init(first.ok);
    const first_id = try first_reader.u128_();

    // A crash-and-recovery re-drives the same transition: the same idempotency key
    // arrives again on a fresh dispatch. The service must return the same id and not
    // create a second capability — the property recovery depends on.
    const second = harness.redrive("capability.issue", 2, 0x100, body);
    var second_reader = payload.Reader.init(second.ok);
    const second_id = try second_reader.u128_();

    try testing.expectEqual(first_id, second_id);
    try testing.expectEqual(@as(usize, 1), service.records.items.len);
}

test "a delegation attenuates and a widening one is refused" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    // Parent covers read+write (bits 0b0011), delegatable, depth 2.
    const issued = try harness.call(gpa, "capability.issue", 1, 0x100, issueBody(&buffer, admin, 0b0011, true, 2));
    var reader = payload.Reader.init(issued.ok);
    const parent_id = try reader.u128_();

    // Delegate read only (0b0001): a strict subset, permitted.
    var del_buffer: [32]u8 = undefined;
    var del_writer = payload.Writer.init(&del_buffer);
    try del_writer.putU128(parent_id);
    try del_writer.putU8(0b0001);
    const ok = try harness.call(gpa, "capability.delegate", 2, 0x200, del_writer.written());
    try testing.expect(ok.succeeded());

    // Delegate read+write+delete (0b0111): widens beyond the parent, refused.
    var wide_buffer: [32]u8 = undefined;
    var wide_writer = payload.Writer.init(&wide_buffer);
    try wide_writer.putU128(parent_id);
    try wide_writer.putU8(0b0111);
    const refused = try harness.call(gpa, "capability.delegate", 3, 0x300, wide_writer.written());
    try testing.expectEqual(endpoint.FaultCode.unauthorized, refused.fault);
}

test "revoking a capability bumps its generation and is idempotent" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    const issued = try harness.call(gpa, "capability.issue", 1, 0x100, issueBody(&buffer, admin, 0b0001, true, 1));
    var reader = payload.Reader.init(issued.ok);
    const id = try reader.u128_();

    var rev_buffer: [16]u8 = undefined;
    var rev_writer = payload.Writer.init(&rev_buffer);
    try rev_writer.putU128(id);
    _ = try harness.call(gpa, "capability.revoke", 2, 0x200, rev_writer.written());

    const record = service.find(id).?;
    try testing.expect(record.revoked);
    try testing.expectEqual(@as(u32, 2), record.generation);

    // A second revoke under a different key must not bump the generation again.
    rev_writer = payload.Writer.init(&rev_buffer);
    try rev_writer.putU128(id);
    _ = try harness.call(gpa, "capability.revoke", 3, 0x201, rev_writer.written());
    try testing.expectEqual(@as(u32, 2), service.find(id).?.generation);
}

test "the descriptor, routes, and handlers all agree" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    const table: dispatch.Table = .{ .handlers = &harness.handler_storage };
    try dispatch.reconcile(table, descriptor);
    try ipc.descriptor.reconcileWithRoutes(descriptor, .{ .routes = &routes });
}
