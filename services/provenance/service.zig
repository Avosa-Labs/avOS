//! The provenance service: the authenticated endpoint that decides whether data of
//! a given origin may flow to a given sink, so the taint boundary is enforced at one
//! place every consequential flow must pass through.
//!
//! The pure `flow` module decides a single flow; this service exposes that decision
//! over typed IPC, so an agent about to send, publish, or pay asks one authority
//! whether the data it is about to act on is allowed to reach that effect. The check
//! is a pure function of origin, sink, and endorsement — it holds no state and
//! changes nothing — so it is a read-only method the endpoint runs under metering and
//! authentication like any other, refusing an untrusted-to-sensitive flow before the
//! caller can complete it.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const flow = @import("flow.zig");

pub const Service = struct {
    reply_buffer: [8]u8 = undefined,

    fn check(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const provenance_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        const sink_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        const endorsement_tag = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const provenance = enumFrom(flow.Provenance, provenance_tag) orelse return .{ .fault = .invalid_input };
        const sink = enumFrom(flow.Sink, sink_tag) orelse return .{ .fault = .invalid_input };
        const endorsement = enumFrom(flow.Endorsement, endorsement_tag) orelse return .{ .fault = .invalid_input };

        const decision = flow.decide(provenance, sink, endorsement);
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putBool(decision.allowed()) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [1]dispatch.Handler {
        return .{
            .{ .method = "provenance.check", .required_capability = "provenance.check", .effect = .read_only, .cost_units = 1, .context = service, .serve = check },
        };
    }
};

fn enumFrom(comptime E: type, tag: u8) ?E {
    const count = @typeInfo(E).@"enum".fields.len;
    if (tag >= count) return null;
    return @enumFromInt(tag);
}

pub const service_id: ipc.routing.ServiceId = 0x0F10;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "provenance.check", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "provenance",
    .methods = &.{
        .{ .name = "provenance.check", .required_capability = "provenance.check", .effect = .read_only },
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

fn body(buffer: []u8, provenance: flow.Provenance, sink: flow.Sink, endorsement: flow.Endorsement) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU8(@intFromEnum(provenance)) catch unreachable;
    writer.putU8(@intFromEnum(sink)) catch unreachable;
    writer.putU8(@intFromEnum(endorsement)) catch unreachable;
    return writer.written();
}

test "untrusted data to a sensitive sink is blocked, and an endorsement bridges it" {
    const gpa = testing.allocator;
    var service: Service = .{};
    var storage = service.handlers();
    var fixture: harness.Fixture = undefined;
    try harness.Fixture.init(gpa, &fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = &storage,
        .prefix = "provenance.",
        .signer = testSigner(),
    });
    defer fixture.deinit();

    var buffer: [8]u8 = undefined;
    const blocked = try fixture.call("provenance.check", 1, 0x1, body(&buffer, .untrusted, .effect, .none));
    var blocked_reader = payload.Reader.init(blocked.ok);
    try testing.expect(!try blocked_reader.boolean());

    const bridged = try fixture.call("provenance.check", 2, 0x2, body(&buffer, .untrusted, .effect, .endorsed));
    var bridged_reader = payload.Reader.init(bridged.ok);
    try testing.expect(try bridged_reader.boolean());
}

test "an out-of-range enum tag is an invalid-input fault, not a crash" {
    const gpa = testing.allocator;
    var service: Service = .{};
    var storage = service.handlers();
    var fixture: harness.Fixture = undefined;
    try harness.Fixture.init(gpa, &fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = &storage,
        .prefix = "provenance.",
        .signer = testSigner(),
    });
    defer fixture.deinit();

    const reply = try fixture.call("provenance.check", 1, 0x1, &[_]u8{ 99, 0, 0 });
    try testing.expectEqual(endpoint.FaultCode.invalid_input, reply.fault);
}
