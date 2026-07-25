//! The resource service: the authenticated endpoint that reserves resource units
//! against a pool and releases them, holding the live commitment so a reservation is
//! admitted against what is actually left and the system reserve stays protected.
//!
//! The pure `admission` module decides whether a reservation fits a pool for a
//! requester's priority; this service holds the pool's live commitment and the
//! reservations outstanding against it. Reserve and release both mutate that
//! commitment, so each is journaled and keyed by idempotency: a re-driven reservation
//! returns the one it already granted rather than committing its units a second time,
//! and a release for a reservation already gone is a harmless no-op, so a restart
//! mid-transition never over- or under-counts the pool.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const admission = @import("admission.zig");

pub const ReservationId = u128;

const Reservation = struct {
    id: ReservationId,
    principal: u128,
    units: u64,
};

const Applied = struct {
    idempotency_key: u128,
    id: ReservationId,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    pool: admission.Pool,
    reservations: std.ArrayListUnmanaged(Reservation) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    next_id: ReservationId = 1,
    reply_buffer: [16]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, capacity: u64, reserved_for_system: u64) Service {
        return .{ .gpa = gpa, .pool = .{ .capacity = capacity, .reserved_for_system = reserved_for_system, .committed = 0 } };
    }

    pub fn deinit(service: *Service) void {
        service.reservations.deinit(service.gpa);
        service.applied.deinit(service.gpa);
        service.* = undefined;
    }

    fn priorId(service: *Service, key: u128) ?ReservationId {
        for (service.applied.items) |entry| {
            if (entry.idempotency_key == key) return entry.id;
        }
        return null;
    }

    fn reserve(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        if (service.priorId(key)) |existing| return service.replyId(existing);

        var reader = payload.Reader.init(call.envelope.payload);
        const units = reader.u64_() catch return .{ .fault = .invalid_input };
        const priority_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };
        const priority: admission.Priority = switch (priority_tag) {
            0 => .ordinary,
            1 => .system,
            else => return .{ .fault = .invalid_input },
        };

        switch (admission.decide(service.pool, priority, units)) {
            .refuse => return .{ .fault = .budget_exhausted },
            .grant => {
                const id = service.next_id;
                service.reservations.append(service.gpa, .{ .id = id, .principal = call.envelope.principal, .units = units }) catch return .{ .fault = .unavailable };
                service.applied.append(service.gpa, .{ .idempotency_key = key, .id = id }) catch {
                    _ = service.reservations.pop();
                    return .{ .fault = .unavailable };
                };
                service.pool.committed += units;
                service.next_id += 1;
                return service.replyId(id);
            },
        }
    }

    fn release(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const id = reader.u128_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        for (service.reservations.items, 0..) |reservation, index| {
            if (reservation.id != id) continue;
            if (reservation.principal != call.envelope.principal) return .{ .fault = .unauthorized };
            service.pool.committed -= @min(reservation.units, service.pool.committed);
            _ = service.reservations.swapRemove(index);
            return service.replyId(id);
        }
        // Releasing an unknown reservation is a no-op, so a re-drive after the
        // release already happened is harmless.
        return service.replyId(id);
    }

    fn replyId(service: *Service, id: ReservationId) dispatch.Reply {
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU128(id) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [2]dispatch.Handler {
        return .{
            .{ .method = "resource.reserve", .required_capability = "resource.reserve", .effect = .local_mutation, .cost_units = 2, .context = service, .serve = reserve },
            .{ .method = "resource.release", .required_capability = "resource.release", .effect = .local_mutation, .cost_units = 1, .context = service, .serve = release },
        };
    }
};

pub const service_id: ipc.routing.ServiceId = 0x0355;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "resource.reserve", .service = service_id },
    .{ .method = "resource.release", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "resource",
    .methods = &.{
        .{ .name = "resource.reserve", .required_capability = "resource.reserve", .effect = .local_mutation },
        .{ .name = "resource.release", .required_capability = "resource.release", .effect = .local_mutation },
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

fn reserveBody(buffer: []u8, units: u64, priority: u8) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU64(units) catch unreachable;
    writer.putU8(priority) catch unreachable;
    return writer.written();
}

fn idBody(buffer: []u8, id: ReservationId) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU128(id) catch unreachable;
    return writer.written();
}

fn fixtureFor(gpa: std.mem.Allocator, service: *Service, storage: *[2]dispatch.Handler, fixture: *harness.Fixture) !void {
    service.* = Service.init(gpa, 1000, 200);
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "resource.",
        .signer = testSigner(),
    });
}

test "a reservation commits units and releasing it returns them" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [2]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    const reserved = try fixture.call("resource.reserve", 1, 0x1, reserveBody(&buffer, 300, 0));
    var reader = payload.Reader.init(reserved.ok);
    const id = try reader.u128_();
    try testing.expectEqual(@as(u64, 300), service.pool.committed);

    _ = try fixture.call("resource.release", 2, 0x2, idBody(&buffer, id));
    try testing.expectEqual(@as(u64, 0), service.pool.committed);
}

test "an ordinary reservation into the reserve is refused, a system one is granted" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [2]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    // General limit is 800; commit 800 first.
    _ = try fixture.call("resource.reserve", 1, 0x1, reserveBody(&buffer, 800, 0));
    // Ordinary into the reserve: refused.
    const refused = try fixture.call("resource.reserve", 2, 0x2, reserveBody(&buffer, 100, 0));
    try testing.expectEqual(endpoint.FaultCode.budget_exhausted, refused.fault);
    // System into the reserve: granted.
    const granted = try fixture.call("resource.reserve", 3, 0x3, reserveBody(&buffer, 100, 1));
    try testing.expect(granted.succeeded());
}

test "a re-driven reservation does not double-commit the pool" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [2]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    const body = reserveBody(&buffer, 250, 0);
    const first = try fixture.call("resource.reserve", 1, 0x7, body);
    var reader = payload.Reader.init(first.ok);
    const id = try reader.u128_();

    const again = fixture.redrive("resource.reserve", 2, 0x7, body);
    var again_reader = payload.Reader.init(again.ok);
    try testing.expectEqual(id, try again_reader.u128_());
    try testing.expectEqual(@as(u64, 250), service.pool.committed);
}
