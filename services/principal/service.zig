//! The principal service: the authenticated endpoint that enrolls principals, the
//! act that creates authority, holding the registry of who exists behind typed IPC
//! and a recovery story that never mints a principal twice.
//!
//! The pure `enrollment` module decides whether an enrollment is permitted — a human
//! only by trusted setup, no principal ever outranking its issuer; this service holds
//! the registry the new principal joins and assigns its identity. Enrollment creates
//! authority, so it is the transition that most needs crash-consistency: a restart
//! between deciding to enroll and recording the principal must not leave a half-made
//! identity, and a re-drive must not create a second one. Every enrollment is keyed by
//! the request's idempotency key, so a recovery re-drive returns the identity already
//! assigned rather than minting another.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const enrollment = @import("enrollment.zig");

pub const PrincipalId = u128;

pub const Enrolled = struct {
    id: PrincipalId,
    kind: enrollment.Kind,
};

const Applied = struct {
    idempotency_key: u128,
    id: PrincipalId,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    registry: std.ArrayListUnmanaged(Enrolled) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    next_id: PrincipalId = 1,
    reply_buffer: [16]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Service {
        return .{ .gpa = gpa };
    }

    pub fn deinit(service: *Service) void {
        service.registry.deinit(service.gpa);
        service.applied.deinit(service.gpa);
        service.* = undefined;
    }

    fn priorId(service: *Service, key: u128) ?PrincipalId {
        for (service.applied.items) |entry| {
            if (entry.idempotency_key == key) return entry.id;
        }
        return null;
    }

    fn enroll(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        if (service.priorId(key)) |existing| return service.replyId(existing);

        var reader = payload.Reader.init(call.envelope.payload);
        const issuer_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        const issuer: enrollment.Issuer = switch (issuer_tag) {
            0 => .trusted_setup,
            1 => .{ .principal = kindFrom(reader.u8_() catch return .{ .fault = .invalid_input }) orelse return .{ .fault = .invalid_input } },
            else => return .{ .fault = .invalid_input },
        };
        const request_kind = kindFrom(reader.u8_() catch return .{ .fault = .invalid_input }) orelse return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        switch (enrollment.decide(issuer, .{ .kind = request_kind })) {
            .refuse => |refusal| return .{ .fault = switch (refusal) {
                .human_needs_trusted_setup, .issuer_not_authorized => .unauthorized,
                .would_escalate => .constraint_violation,
            } },
            .enroll => {
                const id = service.next_id;
                service.registry.append(service.gpa, .{ .id = id, .kind = request_kind }) catch return .{ .fault = .unavailable };
                service.applied.append(service.gpa, .{ .idempotency_key = key, .id = id }) catch {
                    _ = service.registry.pop();
                    return .{ .fault = .unavailable };
                };
                service.next_id += 1;
                return service.replyId(id);
            },
        }
    }

    fn replyId(service: *Service, id: PrincipalId) dispatch.Reply {
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU128(id) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [1]dispatch.Handler {
        return .{
            .{ .method = "principal.enroll", .required_capability = "principal.enroll", .effect = .value_transfer, .cost_units = 3, .context = service, .serve = enroll },
        };
    }
};

/// Maps a wire byte to an enrollment kind, whose values are deliberately not
/// zero-based (agent=1, service=2, human=3 encode authority rank), so an unknown
/// byte is rejected rather than coerced.
fn kindFrom(value: u8) ?enrollment.Kind {
    return switch (value) {
        1 => .agent,
        2 => .service,
        3 => .human,
        else => null,
    };
}

pub const service_id: ipc.routing.ServiceId = 0x0819;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "principal.enroll", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "principal",
    .methods = &.{
        .{ .name = "principal.enroll", .required_capability = "principal.enroll", .effect = .value_transfer },
    },
};

comptime {
    ipc.descriptor.validate(descriptor) catch unreachable;
}

// --- Tests ---

const testing = std.testing;
const harness = @import("../endpoint/harness.zig");
const Ed25519 = std.crypto.sign.Ed25519;

fn testSigner() ipc.authenticator.SigningIdentity {
    return .{ .service = harness.caller, .key_pair = Ed25519.KeyPair.generateDeterministic(@splat(9)) catch unreachable };
}

fn enrollBody(buffer: []u8, issuer_tag: u8, issuer_kind: u8, request_kind: u8) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU8(issuer_tag) catch unreachable;
    if (issuer_tag == 1) writer.putU8(issuer_kind) catch unreachable;
    writer.putU8(request_kind) catch unreachable;
    return writer.written();
}

fn fixtureFor(gpa: std.mem.Allocator, service: *Service, storage: *[1]dispatch.Handler, fixture: *harness.Fixture) !void {
    service.* = Service.init(gpa);
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "principal.",
        .signer = testSigner(),
    });
}

test "trusted setup enrolls a human and a service may enroll an agent" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [8]u8 = undefined;
    // trusted_setup enrolls a human (kind 3).
    const human = try fixture.call("principal.enroll", 1, 0x1, enrollBody(&buffer, 0, 0, 3));
    try testing.expect(human.succeeded());
    // A service (issuer kind 2) enrolls an agent (kind 1).
    const agent = try fixture.call("principal.enroll", 2, 0x2, enrollBody(&buffer, 1, 2, 1));
    try testing.expect(agent.succeeded());
    try testing.expectEqual(@as(usize, 2), service.registry.items.len);
}

test "an agent may not enroll and no issuer may create above itself" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [8]u8 = undefined;
    // An agent (kind 1) issuer tries to enroll anything: not authorized.
    const by_agent = try fixture.call("principal.enroll", 1, 0x1, enrollBody(&buffer, 1, 1, 1));
    try testing.expectEqual(endpoint.FaultCode.unauthorized, by_agent.fault);
    // A service (kind 2) tries to enroll a human (kind 3): a human is created only
    // by trusted setup, so it is refused as unauthorized.
    const human_by_service = try fixture.call("principal.enroll", 2, 0x2, enrollBody(&buffer, 1, 2, 3));
    try testing.expectEqual(endpoint.FaultCode.unauthorized, human_by_service.fault);
}

test "a re-driven enrollment returns the same principal and mints nothing new" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [8]u8 = undefined;
    const body = enrollBody(&buffer, 0, 0, 3);
    const first = try fixture.call("principal.enroll", 1, 0x9, body);
    var first_reader = payload.Reader.init(first.ok);
    const first_id = try first_reader.u128_();

    const again = fixture.redrive("principal.enroll", 2, 0x9, body);
    var again_reader = payload.Reader.init(again.ok);
    try testing.expectEqual(first_id, try again_reader.u128_());
    try testing.expectEqual(@as(usize, 1), service.registry.items.len);
}
