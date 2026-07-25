//! The audit service: the authenticated endpoint that extends the tamper-evident
//! log and verifies it, holding the chain behind typed IPC so an entry is appended
//! in exactly one place, under one rule, with one recovery story.
//!
//! The pure `append` module decides whether a proposed entry validly extends the
//! chain and computes the links; this service holds the chain those decisions are
//! made against, appends to it, and verifies it end to end. The append is the
//! canonical transition that must survive a restart: the log is the record every
//! other subsystem is audited against, and an append that half-happened — a link
//! computed but the entry not stored, or stored twice — would fork or gap the chain
//! and destroy the property the log exists to provide.
//!
//! So the client supplies only the content it wants recorded; the service assigns
//! the sequence and computes the previous link itself, from the chain state it holds,
//! and keys the append by the request's idempotency key. A recovery re-drive of the
//! same append returns the sequence it already assigned rather than appending a
//! second entry, so the chain a restart recovers is exactly the one it would have
//! had without the crash.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const payload = @import("../endpoint/payload.zig");
const append = @import("append.zig");

pub const Entry = append.Entry;
pub const Link = append.Link;

const Applied = struct {
    idempotency_key: u128,
    sequence: u64,
};

/// The audit chain and the endpoint that fronts it.
pub const Service = struct {
    gpa: std.mem.Allocator,
    chain: std.ArrayListUnmanaged(Entry) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply_buffer: [64]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Service {
        return .{ .gpa = gpa };
    }

    pub fn deinit(service: *Service) void {
        service.chain.deinit(service.gpa);
        service.applied.deinit(service.gpa);
        service.* = undefined;
    }

    fn priorSequence(service: *Service, key: u128) ?u64 {
        for (service.applied.items) |entry| {
            if (entry.idempotency_key == key) return entry.sequence;
        }
        return null;
    }

    fn appendHandler(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;

        // A re-driven append returns the sequence already assigned, so the chain is
        // never forked or duplicated by a retry after a crash.
        if (service.priorSequence(key)) |sequence| {
            return service.replyEntry(sequence);
        }

        var reader = payload.Reader.init(call.envelope.payload);
        const content_digest = reader.array(32) catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        // The service assigns the position and previous link from the chain it
        // holds; the client cannot choose them, so it cannot gap or fork the log.
        const sequence: u64 = service.chain.items.len;
        const proposed: Entry = .{
            .sequence = sequence,
            .previous_link = if (service.chain.items.len == 0)
                append.genesis_link
            else
                append.linkAfter(service.chain.items[service.chain.items.len - 1]),
            .content_digest = content_digest,
        };

        // Validate against the pure rule even though the service built it — a bug that
        // ever produced an invalid extension is caught here, not written to the log.
        const decision = if (service.chain.items.len == 0)
            append.decideFirst(proposed)
        else
            append.decideAppend(service.chain.items[service.chain.items.len - 1], proposed);
        if (!decision.appends()) return .{ .fault = .integrity_failure };

        service.chain.append(service.gpa, proposed) catch return .{ .fault = .unavailable };
        service.applied.append(service.gpa, .{ .idempotency_key = key, .sequence = sequence }) catch {
            // Undo the append so the recorded-and-stored invariant holds: an entry is
            // in the chain only if its idempotency key is recorded.
            _ = service.chain.pop();
            return .{ .fault = .unavailable };
        };
        return service.replyEntry(sequence);
    }

    fn verifyHandler(context: *anyopaque, _: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var writer = payload.Writer.init(&service.reply_buffer);
        if (append.verifyChain(service.chain.items)) |broken_index| {
            writer.putBool(false) catch return .{ .fault = .internal_fault };
            writer.putU64(broken_index) catch return .{ .fault = .internal_fault };
        } else {
            writer.putBool(true) catch return .{ .fault = .internal_fault };
            writer.putU64(service.chain.items.len) catch return .{ .fault = .internal_fault };
        }
        return .{ .ok = writer.written() };
    }

    fn replyEntry(service: *Service, sequence: u64) dispatch.Reply {
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU64(sequence) catch return .{ .fault = .internal_fault };
        const link = if (sequence < service.chain.items.len)
            append.linkAfter(service.chain.items[sequence])
        else
            append.genesis_link;
        writer.putArray(&link) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    pub fn handlers(service: *Service) [2]dispatch.Handler {
        return .{
            .{ .method = "audit.append", .required_capability = "audit.append", .effect = .local_mutation, .cost_units = 2, .context = service, .serve = appendHandler },
            .{ .method = "audit.verify", .required_capability = "audit.verify", .effect = .read_only, .cost_units = 1, .context = service, .serve = verifyHandler },
        };
    }
};

pub const service_id: ipc.routing.ServiceId = 0x0A0D;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "audit.append", .service = service_id },
    .{ .method = "audit.verify", .service = service_id },
};

pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "audit",
    .methods = &.{
        .{ .name = "audit.append", .required_capability = "audit.append", .effect = .local_mutation },
        .{ .name = "audit.verify", .required_capability = "audit.verify", .effect = .read_only },
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

fn digestBody(buffer: []u8, fill: u8) []const u8 {
    var writer = payload.Writer.init(buffer);
    const digest: [32]u8 = @splat(fill);
    writer.putArray(&digest) catch unreachable;
    return writer.written();
}

fn setup(gpa: std.mem.Allocator, service: *Service, fixture: *harness.Fixture, storage: *[2]dispatch.Handler) !void {
    service.* = Service.init(gpa);
    storage.* = service.handlers();
    try harness.Fixture.init(gpa, fixture, .{
        .service_id = service_id,
        .routes = .{ .routes = &routes },
        .handlers = storage,
        .prefix = "audit.",
        .signer = testSigner(),
    });
}

test "appends build an intact chain that verifies" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var fixture: harness.Fixture = undefined;
    var storage: [2]dispatch.Handler = undefined;
    try setup(gpa, &service, &fixture, &storage);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [40]u8 = undefined;
    _ = try fixture.call("audit.append", 1, 0x1, digestBody(&buffer, 0xA1));
    _ = try fixture.call("audit.append", 2, 0x2, digestBody(&buffer, 0xB2));
    _ = try fixture.call("audit.append", 3, 0x3, digestBody(&buffer, 0xC3));

    try testing.expectEqual(@as(usize, 3), service.chain.items.len);
    const verify = try fixture.call("audit.verify", 4, 0x4, "");
    var reader = payload.Reader.init(verify.ok);
    try testing.expect(try reader.boolean()); // intact
    try testing.expectEqual(@as(u64, 3), try reader.u64_());
}

test "a re-driven append does not fork or duplicate the chain" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var fixture: harness.Fixture = undefined;
    var storage: [2]dispatch.Handler = undefined;
    try setup(gpa, &service, &fixture, &storage);
    defer fixture.deinit();
    defer service.deinit();

    var buffer: [40]u8 = undefined;
    const body = digestBody(&buffer, 0xA1);
    const first = try fixture.call("audit.append", 1, 0x7, body);
    var first_reader = payload.Reader.init(first.ok);
    const first_seq = try first_reader.u64_();

    // Recovery re-drives the same append: same idempotency key, direct dispatch.
    const again = fixture.redrive("audit.append", 2, 0x7, body);
    var again_reader = payload.Reader.init(again.ok);
    const again_seq = try again_reader.u64_();

    try testing.expectEqual(first_seq, again_seq);
    try testing.expectEqual(@as(usize, 1), service.chain.items.len); // no second entry
    try testing.expect(append.verifyChain(service.chain.items) == null); // still intact
}
