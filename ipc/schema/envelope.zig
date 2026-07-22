//! The inter-service message envelope.
//!
//! Every message between services carries the same header: which protocol it
//! belongs to, which version it was written against, who sent it, which task
//! and capability it acts under, when it stops being worth doing, and whether
//! repeating it is safe. A service therefore never has to infer authority or
//! deadline from context — both travel with the request.
//!
//! Version behavior is explicit. A major version difference is refused: the
//! layout changed and guessing would be worse than failing. A newer minor
//! version is accepted, and fields the reader does not recognize are skipped,
//! so a service can be upgraded without stopping the ones that talk to it.
//!
//! Names such as a version suffix never appear in domain code. Version
//! selection happens here, at the boundary, and nowhere else.

const std = @import("std");
const wire = @import("wire.zig");

/// Identifies this protocol on the wire. A stable technical identifier: once it
/// ships, changing it is a migration, never a rename.
pub const protocol_identifier: u32 = 0x5043_5031;

pub const Version = struct {
    major: u16,
    minor: u16,

    pub fn eql(version: Version, other: Version) bool {
        return version.major == other.major and version.minor == other.minor;
    }
};

/// The version this build writes and expects.
pub const current_version: Version = .{ .major = 1, .minor = 0 };

/// Largest message accepted. A peer that needs more must page, stream, or pass
/// a reference; raising this would let one message consume a service's budget.
pub const max_message_bytes: usize = 64 * 1024;

/// Largest payload within a message, leaving room for the header.
pub const max_payload_bytes: usize = 56 * 1024;

/// Longest method name. Bounded because it is read before anything is
/// dispatched and must not itself become a resource.
pub const max_method_bytes: usize = 64;

/// What a message is asking for or reporting.
pub const Kind = enum(u8) {
    /// Asks a service to do something.
    request = 1,
    /// Reports the result of a request.
    response = 2,
    /// Reports that a request will not be completed.
    fault = 3,
    /// Asks that an in-flight request stop.
    cancel = 4,

    pub fn parse(value: u8) ?Kind {
        return std.enums.fromInt(Kind, value);
    }

    /// Whether a message of this kind may mutate state, and therefore must
    /// carry an idempotency key.
    pub fn mayMutate(kind: Kind) bool {
        return kind == .request;
    }
};

/// Wire error codes.
///
/// Numbered explicitly and never renumbered: a peer built against an older
/// build must read the same meaning from the same number. They map onto the
/// domain error taxonomy at the boundary, so no service interprets a raw number.
pub const FaultCode = enum(u16) {
    unauthorized = 1,
    capability_expired = 2,
    capability_revoked = 3,
    constraint_violation = 4,
    budget_exhausted = 5,
    cancelled = 6,
    deadline_exceeded = 7,
    unavailable = 8,
    invalid_input = 9,
    integrity_failure = 10,
    conflict = 11,
    unsupported = 12,
    internal_fault = 13,

    pub fn parse(value: u16) ?FaultCode {
        return std.enums.fromInt(FaultCode, value);
    }
};

pub const DecodeError = wire.Error || error{
    /// The message belongs to a different protocol.
    ProtocolMismatch,
    /// The major version differs; the layout cannot be assumed.
    IncompatibleVersion,
    /// A field holds a value this build does not define.
    UnknownEnumeration,
    /// A mutating message arrived without an idempotency key.
    MissingIdempotencyKey,
    /// Bytes remain after the message ended.
    TrailingBytes,
};

pub const Envelope = struct {
    version: Version,
    kind: Kind,
    /// Distinguishes one request from another on the same connection.
    correlation: u64,
    /// Key making a repeat of this message safe to detect. Required on
    /// anything that may mutate, so a duplicate delivery after a restart is
    /// recognized rather than performed twice.
    idempotency_key: u128,
    /// The principal on whose authority the message acts.
    principal: u128,
    /// The task the work belongs to. Zero means none.
    task: u128,
    /// The capability authorizing the work. Zero means none.
    capability: u128,
    /// When the request stops being worth doing, in nanoseconds since the
    /// epoch. Zero means no deadline.
    deadline_nanoseconds: i64,
    /// What is being asked of the service.
    method: []const u8,
    /// Set on a fault; ignored otherwise.
    fault: ?FaultCode = null,
    /// Opaque to this layer.
    payload: []const u8,

    /// Bytes this envelope occupies once encoded.
    pub fn encodedSize(envelope: Envelope) usize {
        return 4 + // protocol
            2 + 2 + // version
            1 + // kind
            8 + // correlation
            16 + // idempotency key
            16 + 16 + 16 + // principal, task, capability
            8 + // deadline
            2 + // fault
            4 + envelope.method.len +
            4 + envelope.payload.len;
    }

    pub fn hasDeadline(envelope: Envelope) bool {
        return envelope.deadline_nanoseconds != 0;
    }

    /// Whether the deadline has passed at `now_nanoseconds`.
    pub fn hasExpired(envelope: Envelope, now_nanoseconds: i64) bool {
        if (!envelope.hasDeadline()) return false;
        return now_nanoseconds >= envelope.deadline_nanoseconds;
    }
};

/// Encodes an envelope into `buffer`, returning the written bytes.
///
/// Field order is fixed, so encoding the same envelope always produces the same
/// bytes. That is what lets a signature cover a message and a test vector stay
/// meaningful.
pub fn encode(envelope: Envelope, buffer: []u8) (wire.Error || error{MissingIdempotencyKey})![]const u8 {
    if (envelope.kind.mayMutate() and envelope.idempotency_key == 0) {
        return error.MissingIdempotencyKey;
    }
    if (envelope.encodedSize() > max_message_bytes) return error.LengthExceeded;

    var writer: wire.Writer = .init(buffer);
    try writer.writeU32(protocol_identifier);
    try writer.writeU16(envelope.version.major);
    try writer.writeU16(envelope.version.minor);
    try writer.writeU8(@intFromEnum(envelope.kind));
    try writer.writeU64(envelope.correlation);
    try writer.writeU128(envelope.idempotency_key);
    try writer.writeU128(envelope.principal);
    try writer.writeU128(envelope.task);
    try writer.writeU128(envelope.capability);
    try writer.writeI64(envelope.deadline_nanoseconds);
    try writer.writeU16(if (envelope.fault) |code| @intFromEnum(code) else 0);
    try writer.writeBytes(envelope.method, max_method_bytes);
    try writer.writeBytes(envelope.payload, max_payload_bytes);
    return writer.written();
}

/// Decodes an envelope from `bytes`.
///
/// The result borrows from `bytes` and is valid only while they are. Nothing is
/// allocated: a decoder that allocates on the strength of an attacker-supplied
/// length is a denial-of-service surface.
pub fn decode(bytes: []const u8) DecodeError!Envelope {
    if (bytes.len > max_message_bytes) return error.LengthExceeded;

    var reader: wire.Reader = .init(bytes);

    if (try reader.readU32() != protocol_identifier) return error.ProtocolMismatch;

    const version: Version = .{
        .major = try reader.readU16(),
        .minor = try reader.readU16(),
    };
    // A major difference means the layout changed. Reading on would interpret
    // one field as another, which is worse than refusing.
    if (version.major != current_version.major) return error.IncompatibleVersion;

    const kind = Kind.parse(try reader.readU8()) orelse return error.UnknownEnumeration;
    const correlation = try reader.readU64();
    const idempotency_key = try reader.readU128();
    const principal = try reader.readU128();
    const task = try reader.readU128();
    const capability = try reader.readU128();
    const deadline = try reader.readI64();

    const fault_value = try reader.readU16();
    const fault: ?FaultCode = if (fault_value == 0)
        null
    else
        FaultCode.parse(fault_value) orelse return error.UnknownEnumeration;

    const method = try reader.readBytes(max_method_bytes);
    const payload = try reader.readBytes(max_payload_bytes);

    if (kind.mayMutate() and idempotency_key == 0) return error.MissingIdempotencyKey;

    // A newer minor version may append fields this build does not know. They
    // are skipped so an older reader keeps working, but each is still bounded.
    if (version.minor > current_version.minor) {
        while (!reader.isExhausted()) {
            try reader.skipUnknown(max_payload_bytes);
        }
    }

    // At the same minor version there is nothing left to explain, so anything
    // remaining is a malformed message rather than a newer one.
    if (!reader.isExhausted()) return error.TrailingBytes;

    return .{
        .version = version,
        .kind = kind,
        .correlation = correlation,
        .idempotency_key = idempotency_key,
        .principal = principal,
        .task = task,
        .capability = capability,
        .deadline_nanoseconds = deadline,
        .method = method,
        .fault = fault,
        .payload = payload,
    };
}

const sample_key: u128 = 0x0f0e0d0c0b0a09080706050403020100;

fn sampleRequest() Envelope {
    return .{
        .version = current_version,
        .kind = .request,
        .correlation = 7,
        .idempotency_key = sample_key,
        .principal = 0x1111,
        .task = 0x2222,
        .capability = 0x3333,
        .deadline_nanoseconds = 1_767_225_600 * std.time.ns_per_s,
        .method = "calendar.read",
        .payload = "the request body",
    };
}

test "an envelope round-trips unchanged" {
    var buffer: [max_message_bytes]u8 = undefined;
    const encoded = try encode(sampleRequest(), &buffer);
    const decoded = try decode(encoded);

    try std.testing.expect(decoded.version.eql(current_version));
    try std.testing.expectEqual(Kind.request, decoded.kind);
    try std.testing.expectEqual(@as(u64, 7), decoded.correlation);
    try std.testing.expectEqual(sample_key, decoded.idempotency_key);
    try std.testing.expectEqual(@as(u128, 0x3333), decoded.capability);
    try std.testing.expectEqualStrings("calendar.read", decoded.method);
    try std.testing.expectEqualStrings("the request body", decoded.payload);
    try std.testing.expectEqual(@as(?FaultCode, null), decoded.fault);
}

test "encoding is byte-identical across runs" {
    // A signature covers these bytes, so the same envelope must always produce
    // the same encoding.
    var first: [max_message_bytes]u8 = undefined;
    var second: [max_message_bytes]u8 = undefined;
    const a = try encode(sampleRequest(), &first);
    const b = try encode(sampleRequest(), &second);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "a message from another protocol is refused" {
    var buffer: [64]u8 = undefined;
    var writer: wire.Writer = .init(&buffer);
    try writer.writeU32(0xdead_beef);
    try std.testing.expectError(error.ProtocolMismatch, decode(writer.written()));
}

test "a different major version is refused rather than guessed" {
    var buffer: [max_message_bytes]u8 = undefined;
    var envelope = sampleRequest();
    envelope.version = .{ .major = current_version.major + 1, .minor = 0 };
    const encoded = try encode(envelope, &buffer);
    try std.testing.expectError(error.IncompatibleVersion, decode(encoded));
}

test "a newer minor version is accepted and its unknown fields are skipped" {
    var buffer: [max_message_bytes]u8 = undefined;
    var envelope = sampleRequest();
    envelope.version = .{ .major = current_version.major, .minor = current_version.minor + 1 };
    const encoded = try encode(envelope, &buffer);

    // Append a field this build does not know about.
    var extended: [max_message_bytes]u8 = undefined;
    @memcpy(extended[0..encoded.len], encoded);
    var appender: wire.Writer = .init(extended[encoded.len..]);
    try appender.writeBytes("a field added by a newer peer", max_payload_bytes);

    const total = encoded.len + appender.written().len;
    const decoded = try decode(extended[0..total]);

    try std.testing.expectEqualStrings("calendar.read", decoded.method);
    try std.testing.expectEqualStrings("the request body", decoded.payload);
}

test "trailing bytes at the same version are malformed" {
    var buffer: [max_message_bytes]u8 = undefined;
    const encoded = try encode(sampleRequest(), &buffer);

    var extended: [max_message_bytes]u8 = undefined;
    @memcpy(extended[0..encoded.len], encoded);
    extended[encoded.len] = 0;

    try std.testing.expectError(error.TrailingBytes, decode(extended[0 .. encoded.len + 1]));
}

test "a mutating message without an idempotency key is refused at both ends" {
    var envelope = sampleRequest();
    envelope.idempotency_key = 0;

    var buffer: [max_message_bytes]u8 = undefined;
    try std.testing.expectError(error.MissingIdempotencyKey, encode(envelope, &buffer));

    // A peer that skips the encoder must still be refused on receipt.
    var writer: wire.Writer = .init(&buffer);
    try writer.writeU32(protocol_identifier);
    try writer.writeU16(current_version.major);
    try writer.writeU16(current_version.minor);
    try writer.writeU8(@intFromEnum(Kind.request));
    try writer.writeU64(1);
    try writer.writeU128(0);
    try writer.writeU128(0x1111);
    try writer.writeU128(0);
    try writer.writeU128(0);
    try writer.writeI64(0);
    try writer.writeU16(0);
    try writer.writeBytes("calendar.read", max_method_bytes);
    try writer.writeBytes("", max_payload_bytes);

    try std.testing.expectError(error.MissingIdempotencyKey, decode(writer.written()));
}

test "a response needs no idempotency key" {
    var envelope = sampleRequest();
    envelope.kind = .response;
    envelope.idempotency_key = 0;

    var buffer: [max_message_bytes]u8 = undefined;
    const decoded = try decode(try encode(envelope, &buffer));
    try std.testing.expectEqual(Kind.response, decoded.kind);
}

test "an undefined kind or fault code is refused" {
    var buffer: [max_message_bytes]u8 = undefined;
    var writer: wire.Writer = .init(&buffer);
    try writer.writeU32(protocol_identifier);
    try writer.writeU16(current_version.major);
    try writer.writeU16(current_version.minor);
    try writer.writeU8(99);
    try std.testing.expectError(error.UnknownEnumeration, decode(writer.written()));

    var fault_buffer: [max_message_bytes]u8 = undefined;
    var envelope = sampleRequest();
    envelope.kind = .fault;
    envelope.fault = .unauthorized;
    const encoded = try encode(envelope, &fault_buffer);
    // Overwrite the fault code with one this build does not define.
    const fault_offset = 4 + 2 + 2 + 1 + 8 + 16 + 16 + 16 + 16 + 8;
    var tampered: [max_message_bytes]u8 = undefined;
    @memcpy(tampered[0..encoded.len], encoded);
    std.mem.writeInt(u16, tampered[fault_offset..][0..2], 999, .little);
    try std.testing.expectError(error.UnknownEnumeration, decode(tampered[0..encoded.len]));
}

test "an oversized message is refused before it is parsed" {
    const oversized: [max_message_bytes + 1]u8 = @splat(0);
    try std.testing.expectError(error.LengthExceeded, decode(&oversized));
}

test "an oversized payload cannot be encoded" {
    const gpa = std.testing.allocator;
    const payload = try gpa.alloc(u8, max_payload_bytes + 1);
    defer gpa.free(payload);
    @memset(payload, 0);

    var envelope = sampleRequest();
    envelope.payload = payload;

    const buffer = try gpa.alloc(u8, max_message_bytes * 2);
    defer gpa.free(buffer);
    try std.testing.expectError(error.LengthExceeded, encode(envelope, buffer));
}

test "truncating a message anywhere is detected" {
    var buffer: [max_message_bytes]u8 = undefined;
    const encoded = try encode(sampleRequest(), &buffer);

    // Every prefix short of the whole message must be rejected, not
    // half-interpreted.
    var length: usize = 0;
    while (length < encoded.len) : (length += 1) {
        try std.testing.expect(decode(encoded[0..length]) catch |failure| blk: {
            const expected = failure == error.Truncated or
                failure == error.ProtocolMismatch or
                failure == error.LengthExceeded;
            try std.testing.expect(expected);
            break :blk null;
        } == null);
    }
}

test "flipping any single bit is detected or changes an observable field" {
    var buffer: [max_message_bytes]u8 = undefined;
    const encoded = try encode(sampleRequest(), &buffer);

    var corrupted: [max_message_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(corrupted[0..encoded.len], encoded);
        corrupted[index] ^= 0x01;

        const decoded = decode(corrupted[0..encoded.len]) catch continue;
        // If it still decodes, at least one field must differ; a corruption
        // that decodes identically would mean an ignored byte.
        const original = try decode(encoded);
        const differs = decoded.correlation != original.correlation or
            decoded.idempotency_key != original.idempotency_key or
            decoded.principal != original.principal or
            decoded.task != original.task or
            decoded.capability != original.capability or
            decoded.deadline_nanoseconds != original.deadline_nanoseconds or
            decoded.kind != original.kind or
            !std.mem.eql(u8, decoded.method, original.method) or
            !std.mem.eql(u8, decoded.payload, original.payload) or
            decoded.fault != original.fault or
            !decoded.version.eql(original.version);
        try std.testing.expect(differs);
    }
}

test "a deadline is evaluated against a supplied instant" {
    const envelope = sampleRequest();
    try std.testing.expect(envelope.hasDeadline());
    try std.testing.expect(!envelope.hasExpired(envelope.deadline_nanoseconds - 1));
    try std.testing.expect(envelope.hasExpired(envelope.deadline_nanoseconds));
    try std.testing.expect(envelope.hasExpired(envelope.deadline_nanoseconds + 1));

    var without = envelope;
    without.deadline_nanoseconds = 0;
    try std.testing.expect(!without.hasDeadline());
    try std.testing.expect(!without.hasExpired(std.math.maxInt(i64)));
}

test "every fault code parses back to itself" {
    for (std.enums.values(FaultCode)) |code| {
        try std.testing.expectEqual(code, FaultCode.parse(@intFromEnum(code)).?);
    }
    try std.testing.expectEqual(@as(?FaultCode, null), FaultCode.parse(0));
    try std.testing.expectEqual(@as(?FaultCode, null), FaultCode.parse(9999));
}

test "only a request may mutate" {
    try std.testing.expect(Kind.request.mayMutate());
    try std.testing.expect(!Kind.response.mayMutate());
    try std.testing.expect(!Kind.fault.mayMutate());
    try std.testing.expect(!Kind.cancel.mayMutate());
}
