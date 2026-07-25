//! The session service: the authenticated endpoint that decides whether a session
//! should stay open or lock, so the rule that protects idle and sensitive contexts
//! is applied uniformly rather than reinvented by each surface.
//!
//! The pure `lock` module decides a lock from the context's sensitivity, how long it
//! has been idle, and any immediate trigger; this service exposes that decision over
//! typed IPC. It is a read-only evaluation — the shell holds the session state and
//! acts on the answer — but centralizing it means a high-value context locks on the
//! same short timer everywhere, and an authentication-lost or security event locks at
//! once, without each surface having to remember to check.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const lock = @import("lock.zig");

pub const Service = struct {
    reply_buffer: [8]u8 = undefined,

    fn evaluate(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const sensitivity_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        const idle_ms_raw = reader.u64_() catch return .{ .fault = .invalid_input };
        const trigger_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const sensitivity = enumFrom(lock.Sensitivity, sensitivity_tag) orelse return .{ .fault = .invalid_input };
        const trigger = enumFrom(lock.Trigger, trigger_tag) orelse return .{ .fault = .invalid_input };
        const idle_ms = std.math.cast(i64, idle_ms_raw) orelse return .{ .fault = .invalid_input };

        const decision = lock.evaluate(sensitivity, idle_ms, trigger);
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putBool(decision.locks()) catch return .{ .fault = .internal_fault };
        writer.putU8(switch (decision) {
            .stay_open => 0,
            .lock => |reason| @as(u8, @intFromEnum(reason)) + 1,
        }) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [1]dispatch.Handler {
        return .{
            .{ .method = "session.evaluate", .required_capability = "session.evaluate", .effect = .read_only, .cost_units = 1, .context = service, .serve = evaluate },
        };
    }
};

fn enumFrom(comptime E: type, tag: u8) ?E {
    if (tag >= @typeInfo(E).@"enum".fields.len) return null;
    return @enumFromInt(tag);
}

pub const service_id: ipc.routing.ServiceId = 0x5E55;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "session.evaluate", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "session",
    .methods = &.{
        .{ .name = "session.evaluate", .required_capability = "session.evaluate", .effect = .read_only },
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

fn body(buffer: []u8, sensitivity: lock.Sensitivity, idle_ms: u64, trigger: lock.Trigger) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU8(@intFromEnum(sensitivity)) catch unreachable;
    writer.putU64(idle_ms) catch unreachable;
    writer.putU8(@intFromEnum(trigger)) catch unreachable;
    return writer.written();
}

fn fixtureFor(gpa: std.mem.Allocator, service: *Service, storage: *[1]dispatch.Handler, fixture: *harness.Fixture) !void {
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "session.",
        .signer = testSigner(),
    });
}

test "a high-value context past its short timeout locks, an ordinary one within its timer stays open" {
    const gpa = testing.allocator;
    var service: Service = .{};
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();

    var buffer: [16]u8 = undefined;
    const locked = try fixture.call("session.evaluate", 1, 0x1, body(&buffer, .high_value, 60_000, .none));
    var locked_reader = payload.Reader.init(locked.ok);
    try testing.expect(try locked_reader.boolean());

    const open = try fixture.call("session.evaluate", 2, 0x2, body(&buffer, .ordinary, 1_000, .none));
    var open_reader = payload.Reader.init(open.ok);
    try testing.expect(!try open_reader.boolean());
}

test "an authentication-lost trigger locks immediately regardless of idle time" {
    const gpa = testing.allocator;
    var service: Service = .{};
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();

    var buffer: [16]u8 = undefined;
    const reply = try fixture.call("session.evaluate", 1, 0x1, body(&buffer, .ordinary, 0, .authentication_lost));
    var reader = payload.Reader.init(reply.ok);
    try testing.expect(try reader.boolean()); // locked
    // Reason code 1 + authentication_lost's index.
    try testing.expectEqual(@as(u8, @intFromEnum(lock.Reason.authentication_lost) + 1), try reader.u8_());
}
