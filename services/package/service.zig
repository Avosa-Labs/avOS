//! The package service: the authenticated endpoint that verifies a package before
//! it may be installed, so an unsigned, tampered, downgraded, or wrong-platform
//! package is refused at one gate rather than by whoever happens to install it.
//!
//! The pure `verify` module decides a package's fitness from its own fields; this
//! service exposes that decision over typed IPC as the single authority the installer
//! consults. Verification changes nothing, so it is a read-only method — but it is
//! the gate that makes installation safe: a package whose signature does not verify
//! is refused before any of its other claims are even considered, so unverified code
//! never reaches the device on the strength of a version number it asserted itself.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const verify = @import("verify.zig");

pub const Service = struct {
    reply_buffer: [8]u8 = undefined,

    fn verifyHandler(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const signature_valid = reader.boolean() catch return .{ .fault = .invalid_input };
        const version = reader.u64_() catch return .{ .fault = .invalid_input };
        const installed = reader.u64_() catch return .{ .fault = .invalid_input };
        const platform = reader.blob() catch return .{ .fault = .invalid_input };
        const device_platform = reader.blob() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const verdict = verify.verify(.{
            .signature_valid = signature_valid,
            .version = std.math.cast(u32, version) orelse return .{ .fault = .invalid_input },
            .installed_version = std.math.cast(u32, installed) orelse return .{ .fault = .invalid_input },
            .platform = platform,
            .device_platform = device_platform,
        });

        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putBool(verdict.admitted()) catch return .{ .fault = .internal_fault };
        writer.putU8(switch (verdict) {
            .admit => 0,
            .refuse => |refusal| @as(u8, @intFromEnum(refusal)) + 1,
        }) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [1]dispatch.Handler {
        return .{
            .{ .method = "package.verify", .required_capability = "package.verify", .effect = .read_only, .cost_units = 2, .context = service, .serve = verifyHandler },
        };
    }
};

pub const service_id: ipc.routing.ServiceId = 0x0BCE;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "package.verify", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "package",
    .methods = &.{
        .{ .name = "package.verify", .required_capability = "package.verify", .effect = .read_only },
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

fn body(buffer: []u8, signed: bool, version: u64, installed: u64, platform: []const u8, device: []const u8) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putBool(signed) catch unreachable;
    writer.putU64(version) catch unreachable;
    writer.putU64(installed) catch unreachable;
    writer.putU16(@intCast(platform.len)) catch unreachable;
    writer.putArray(platform) catch unreachable;
    writer.putU16(@intCast(device.len)) catch unreachable;
    writer.putArray(device) catch unreachable;
    return writer.written();
}

fn fixtureFor(gpa: std.mem.Allocator, service: *Service, storage: *[1]dispatch.Handler, fixture: *harness.Fixture) !void {
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "package.",
        .signer = testSigner(),
    });
}

test "a signed, current, matching package is admitted" {
    const gpa = testing.allocator;
    var service: Service = .{};
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();

    var buffer: [64]u8 = undefined;
    const reply = try fixture.call("package.verify", 1, 0x1, body(&buffer, true, 3, 2, "arm64", "arm64"));
    var reader = payload.Reader.init(reply.ok);
    try testing.expect(try reader.boolean()); // admitted
}

test "an unsigned package is refused as an invalid signature before anything else" {
    const gpa = testing.allocator;
    var service: Service = .{};
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();

    var buffer: [64]u8 = undefined;
    // Unsigned, but otherwise current and matching: it must still be refused.
    const reply = try fixture.call("package.verify", 1, 0x1, body(&buffer, false, 3, 2, "arm64", "arm64"));
    var reader = payload.Reader.init(reply.ok);
    try testing.expect(!try reader.boolean()); // refused
    // Refusal code 1 == invalid_signature (enum index 0, +1).
    try testing.expectEqual(@as(u8, 1), try reader.u8_());
}
