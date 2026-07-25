//! The secret service: the authenticated endpoint that decides whether a principal
//! may access a secret, holding the closed allow-list and the per-principal failure
//! records, and returning only the decision — never the material, never in a log.
//!
//! The pure `secret` module decides an access against a closed allow-list and locks
//! out a guesser; this service holds that state and exposes the decision over typed
//! IPC. Two properties make it different from the other services. It is sensitive:
//! its reply carries a permission, never the secret bytes, so nothing about the
//! material reaches this path, and the handler is marked so the endpoint keeps its
//! reply out of any diagnostic — a secret that is never in a reply cannot be leaked by
//! one. And its decision mutates the failure record, so it is keyed by idempotency: a
//! re-driven access after a crash returns the decision it already made rather than
//! counting a second failure, so recovery cannot itself push a principal toward
//! lockout.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const secret = @import("secret.zig");

const Applied = struct {
    idempotency_key: u128,
    granted: bool,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    grants: []const secret.Grant,
    failures: std.ArrayListUnmanaged(secret.FailureRecord) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply_buffer: [4]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, grants: []const secret.Grant) Service {
        return .{ .gpa = gpa, .grants = grants };
    }

    pub fn deinit(service: *Service) void {
        service.failures.deinit(service.gpa);
        service.applied.deinit(service.gpa);
        service.* = undefined;
    }

    fn priorGrant(service: *Service, key: u128) ?bool {
        for (service.applied.items) |entry| {
            if (entry.idempotency_key == key) return entry.granted;
        }
        return null;
    }

    fn access(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        // A re-driven access returns the recorded decision, so recovery does not
        // count a second failure toward lockout.
        if (service.priorGrant(key)) |granted| return service.reply(granted);

        var reader = payload.Reader.init(call.envelope.payload);
        const secret_id = reader.u64_() catch return .{ .fault = .invalid_input };
        const operation_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };
        const operation = enumFrom(secret.Operation, operation_tag) orelse return .{ .fault = .invalid_input };

        // Ensure a failure record exists for the principal so access can update it.
        service.ensureRecord(call.envelope.principal) catch return .{ .fault = .unavailable };
        const pure: secret.Service = .{ .grants = service.grants, .failures = service.failures.items };
        const decision = pure.access(.{
            .principal = call.envelope.principal,
            .secret_id = secret_id,
            .operation = operation,
        });

        service.applied.append(service.gpa, .{ .idempotency_key = key, .granted = decision.granted() }) catch return .{ .fault = .unavailable };
        if (decision.granted()) return service.reply(true);
        return switch (decision.outcome) {
            .refuse => |refusal| switch (refusal) {
                // A locked-out principal is told only that it is refused; the reply
                // never distinguishes "wrong" from "does not exist" beyond the fault.
                .locked_out => .{ .fault = .unavailable },
                .not_granted => .{ .fault = .unauthorized },
            },
            .grant => service.reply(true),
        };
    }

    fn ensureRecord(service: *Service, principal: u128) !void {
        for (service.failures.items) |record| {
            if (record.principal == principal) return;
        }
        try service.failures.append(service.gpa, .{ .principal = principal });
    }

    /// A reply carries only the permission, never the secret material. The material
    /// is delivered to a granted caller through a sealed channel, not this path, so
    /// this endpoint has nothing to redact because it never holds a secret.
    fn reply(service: *Service, granted: bool) dispatch.Reply {
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putBool(granted) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [1]dispatch.Handler {
        return .{
            .{ .method = "secret.access", .required_capability = "secret.access", .effect = .local_mutation, .cost_units = 2, .sensitive = true, .context = service, .serve = access },
        };
    }
};

fn enumFrom(comptime E: type, tag: u8) ?E {
    if (tag >= @typeInfo(E).@"enum".fields.len) return null;
    return @enumFromInt(tag);
}

pub const service_id: ipc.routing.ServiceId = 0x5EC7;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "secret.access", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "secret",
    .methods = &.{
        .{ .name = "secret.access", .required_capability = "secret.access", .effect = .local_mutation },
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

const test_grants = [_]secret.Grant{
    .{ .principal = harness.caller, .secret_id = 42, .operation = .read },
};

fn accessBody(buffer: []u8, secret_id: u64, operation: secret.Operation) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU64(secret_id) catch unreachable;
    writer.putU8(@intFromEnum(operation)) catch unreachable;
    return writer.written();
}

fn fixtureFor(gpa: std.mem.Allocator, service: *Service, storage: *[1]dispatch.Handler, fixture: *harness.Fixture) !void {
    service.* = Service.init(gpa, &test_grants);
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "secret.",
        .signer = testSigner(),
    });
}

test "a granted access returns a permission and never the material" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    const reply = try fixture.call("secret.access", 1, 0x1, accessBody(&buffer, 42, .read));
    try testing.expect(reply.succeeded());
    // The reply is exactly one byte — the permission — with no room for material.
    try testing.expectEqual(@as(usize, 1), reply.ok.len);
    var reader = payload.Reader.init(reply.ok);
    try testing.expect(try reader.boolean());
}

test "an ungranted access is unauthorized" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    // secret 42 is granted for read, not rotate.
    const reply = try fixture.call("secret.access", 1, 0x1, accessBody(&buffer, 42, .rotate));
    try testing.expectEqual(endpoint.FaultCode.unauthorized, reply.fault);
}

test "a re-driven access does not count a second failure toward lockout" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    const body = accessBody(&buffer, 99, .read); // no grant: a failure
    _ = try fixture.call("secret.access", 1, 0x7, body);
    const failures_after_first = service.failures.items[0].failures;

    // Recovery re-drives the same denied access: the failure count must not rise.
    _ = fixture.redrive("secret.access", 2, 0x7, body);
    try testing.expectEqual(failures_after_first, service.failures.items[0].failures);
}
