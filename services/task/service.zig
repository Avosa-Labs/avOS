//! The task service: the authenticated endpoint that admits and completes a
//! principal's tasks, holding each principal's in-flight count and committed budget
//! so a submission is admitted against what that principal actually has left.
//!
//! The pure `admission` module decides whether a submission fits a principal's
//! limits; this service holds those limits and the live usage they are checked
//! against, admitting a task by committing its units and freeing them on completion.
//! Admission and completion both mutate that usage, so each is journaled and keyed by
//! idempotency: a re-driven submission returns the task it already admitted rather
//! than committing its units twice, and a re-driven completion is a no-op once the
//! task is gone, so a restart mid-transition neither double-charges a budget nor
//! releases a task that never ran.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const admission = @import("admission.zig");

pub const TaskId = u128;

/// A principal's live task usage against its limits.
const Usage = struct {
    principal: u128,
    in_flight: u32 = 0,
    committed_units: u64 = 0,
};

const Task = struct {
    id: TaskId,
    principal: u128,
    units: u64,
};

const Applied = struct {
    idempotency_key: u128,
    id: TaskId,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    /// The limits every principal is held to. One set for the whole service keeps the
    /// admission rule the same for every caller.
    max_in_flight: u32,
    unit_budget: u64,
    usage: std.ArrayListUnmanaged(Usage) = .empty,
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    next_id: TaskId = 1,
    reply_buffer: [16]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, max_in_flight: u32, unit_budget: u64) Service {
        return .{ .gpa = gpa, .max_in_flight = max_in_flight, .unit_budget = unit_budget };
    }

    pub fn deinit(service: *Service) void {
        service.usage.deinit(service.gpa);
        service.tasks.deinit(service.gpa);
        service.applied.deinit(service.gpa);
        service.* = undefined;
    }

    fn usageFor(service: *Service, principal: u128) !*Usage {
        for (service.usage.items) |*entry| {
            if (entry.principal == principal) return entry;
        }
        try service.usage.append(service.gpa, .{ .principal = principal });
        return &service.usage.items[service.usage.items.len - 1];
    }

    fn priorId(service: *Service, key: u128) ?TaskId {
        for (service.applied.items) |entry| {
            if (entry.idempotency_key == key) return entry.id;
        }
        return null;
    }

    fn submit(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        if (service.priorId(key)) |existing| return service.replyId(existing);

        var reader = payload.Reader.init(call.envelope.payload);
        const units = reader.u64_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const usage = service.usageFor(call.envelope.principal) catch return .{ .fault = .unavailable };
        switch (admission.decide(.{
            .in_flight = usage.in_flight,
            .max_in_flight = service.max_in_flight,
            .committed_units = usage.committed_units,
            .unit_budget = service.unit_budget,
        }, .{ .units = units })) {
            .refuse => |refusal| return .{ .fault = switch (refusal) {
                .too_many_in_flight => .unavailable,
                .over_budget => .budget_exhausted,
            } },
            .admit => {
                const id = service.next_id;
                service.tasks.append(service.gpa, .{ .id = id, .principal = call.envelope.principal, .units = units }) catch return .{ .fault = .unavailable };
                service.applied.append(service.gpa, .{ .idempotency_key = key, .id = id }) catch {
                    _ = service.tasks.pop();
                    return .{ .fault = .unavailable };
                };
                usage.in_flight += 1;
                usage.committed_units += units;
                service.next_id += 1;
                return service.replyId(id);
            },
        }
    }

    fn complete(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const id = reader.u128_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        for (service.tasks.items, 0..) |task, index| {
            if (task.id != id) continue;
            // Only the principal that submitted a task may complete it.
            if (task.principal != call.envelope.principal) return .{ .fault = .unauthorized };
            if (service.usageFor(task.principal)) |usage| {
                if (usage.in_flight > 0) usage.in_flight -= 1;
                usage.committed_units -= @min(task.units, usage.committed_units);
            } else |_| {}
            _ = service.tasks.swapRemove(index);
            return service.replyId(id);
        }
        // A completion for an unknown task is a no-op, not an error: a re-driven
        // completion after the task is already gone must be harmless.
        return service.replyId(id);
    }

    fn replyId(service: *Service, id: TaskId) dispatch.Reply {
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU128(id) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [2]dispatch.Handler {
        return .{
            .{ .method = "task.submit", .required_capability = "task.submit", .effect = .local_mutation, .cost_units = 2, .context = service, .serve = submit },
            .{ .method = "task.complete", .required_capability = "task.complete", .effect = .local_mutation, .cost_units = 1, .context = service, .serve = complete },
        };
    }
};

pub const service_id: ipc.routing.ServiceId = 0x0723;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "task.submit", .service = service_id },
    .{ .method = "task.complete", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "task",
    .methods = &.{
        .{ .name = "task.submit", .required_capability = "task.submit", .effect = .local_mutation },
        .{ .name = "task.complete", .required_capability = "task.complete", .effect = .local_mutation },
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

fn unitsBody(buffer: []u8, units: u64) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU64(units) catch unreachable;
    return writer.written();
}

fn idBody(buffer: []u8, id: TaskId) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU128(id) catch unreachable;
    return writer.written();
}

fn fixtureFor(gpa: std.mem.Allocator, service: *Service, storage: *[2]dispatch.Handler, fixture: *harness.Fixture) !void {
    service.* = Service.init(gpa, 2, 100);
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "task.",
        .signer = testSigner(),
    });
}

test "a task is admitted, and completing it frees its budget for another" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [2]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    const submitted = try fixture.call("task.submit", 1, 0x1, unitsBody(&buffer, 80));
    var reader = payload.Reader.init(submitted.ok);
    const id = try reader.u128_();
    try testing.expectEqual(@as(u64, 80), service.usage.items[0].committed_units);

    _ = try fixture.call("task.complete", 2, 0x2, idBody(&buffer, id));
    try testing.expectEqual(@as(u64, 0), service.usage.items[0].committed_units);
    try testing.expectEqual(@as(u32, 0), service.usage.items[0].in_flight);
}

test "a submission over the unit budget is refused as budget exhausted" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [2]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    const reply = try fixture.call("task.submit", 1, 0x1, unitsBody(&buffer, 200));
    try testing.expectEqual(endpoint.FaultCode.budget_exhausted, reply.fault);
}

test "a re-driven submission does not commit its units twice" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [2]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [16]u8 = undefined;
    const body = unitsBody(&buffer, 50);
    const first = try fixture.call("task.submit", 1, 0x7, body);
    var reader = payload.Reader.init(first.ok);
    const id = try reader.u128_();

    const again = fixture.redrive("task.submit", 2, 0x7, body);
    var again_reader = payload.Reader.init(again.ok);
    try testing.expectEqual(id, try again_reader.u128_());
    // Committed once, not twice.
    try testing.expectEqual(@as(u64, 50), service.usage.items[0].committed_units);
    try testing.expectEqual(@as(usize, 1), service.tasks.items.len);
}
