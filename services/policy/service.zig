//! The policy service: the authenticated endpoint that evaluates an access request
//! against the device's policy rules, so "may this subject do this to that" is
//! answered in one place, fail-closed, for every caller.
//!
//! The pure `policy` module evaluates a request against a rule set with
//! deny-overrides; this service holds the rule set and exposes the evaluation over
//! typed IPC. Evaluation changes nothing, so it is a read-only method — but it is the
//! authority the whole platform defers to for "is this allowed", and it answers with
//! both the nuanced decision (permit, deny, or unaddressed) and the fail-closed
//! boolean, so a caller can distinguish a forbidden request from an unspoken one
//! while never mistaking a gap in the rules for permission.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const policy = @import("policy.zig");

/// The policy service and the rule set it evaluates against.
pub const Service = struct {
    rules: []const policy.Rule,
    reply_buffer: [8]u8 = undefined,

    pub fn init(rules: []const policy.Rule) Service {
        return .{ .rules = rules };
    }

    fn evaluate(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const subject = reader.blob() catch return .{ .fault = .invalid_input };
        const action = reader.blob() catch return .{ .fault = .invalid_input };
        const resource = reader.blob() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const request: policy.Request = .{ .subject = subject, .action = action, .resource = resource };
        const decision = policy.evaluate(service.rules, request);

        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU8(@intFromEnum(decision)) catch return .{ .fault = .internal_fault };
        writer.putBool(decision.isPermit()) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [1]dispatch.Handler {
        return .{
            .{ .method = "policy.evaluate", .required_capability = "policy.evaluate", .effect = .read_only, .cost_units = 1, .context = service, .serve = evaluate },
        };
    }
};

pub const service_id: ipc.routing.ServiceId = 0x0901;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "policy.evaluate", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "policy",
    .methods = &.{
        .{ .name = "policy.evaluate", .required_capability = "policy.evaluate", .effect = .read_only },
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

const test_rules = [_]policy.Rule{
    .{ .effect = .permit, .subject = "calendar-agent", .action = "read", .resource = "calendar" },
    .{ .effect = .deny, .subject = policy.any, .action = "delete", .resource = "calendar" },
};

fn requestBody(buffer: []u8, subject: []const u8, action: []const u8, resource: []const u8) []const u8 {
    var writer = payload.Writer.init(buffer);
    inline for (.{ subject, action, resource }) |field| {
        writer.putU16(@intCast(field.len)) catch unreachable;
        writer.putArray(field) catch unreachable;
    }
    return writer.written();
}

fn fixtureFor(gpa: std.mem.Allocator, service: *Service, storage: *[1]dispatch.Handler, fixture: *harness.Fixture) !void {
    service.* = Service.init(&test_rules);
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "policy.",
        .signer = testSigner(),
    });
}

test "a permitted request is authorized and a denied one is not" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();

    var buffer: [96]u8 = undefined;
    const permit = try fixture.call("policy.evaluate", 1, 0x1, requestBody(&buffer, "calendar-agent", "read", "calendar"));
    var permit_reader = payload.Reader.init(permit.ok);
    try testing.expectEqual(@intFromEnum(policy.Decision.permit), try permit_reader.u8_());
    try testing.expect(try permit_reader.boolean());

    const deny = try fixture.call("policy.evaluate", 2, 0x2, requestBody(&buffer, "calendar-agent", "delete", "calendar"));
    var deny_reader = payload.Reader.init(deny.ok);
    try testing.expectEqual(@intFromEnum(policy.Decision.deny), try deny_reader.u8_());
    try testing.expect(!try deny_reader.boolean());
}

test "an unaddressed request is not applicable and fail-closed refuses it" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var storage: [1]dispatch.Handler = undefined;
    var fixture: harness.Fixture = undefined;
    try fixtureFor(gpa, &service, &storage, &fixture);
    defer fixture.deinit();

    var buffer: [96]u8 = undefined;
    const reply = try fixture.call("policy.evaluate", 1, 0x1, requestBody(&buffer, "someone", "write", "notes"));
    var reader = payload.Reader.init(reply.ok);
    try testing.expectEqual(@intFromEnum(policy.Decision.not_applicable), try reader.u8_());
    try testing.expect(!try reader.boolean()); // fail-closed
}
