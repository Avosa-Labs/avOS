//! Canonical encoded messages that pin the wire format, so a second
//! implementation can be checked against the same bytes this one produces.
//!
//! The envelope encodes byte-identically for a given message, which is what lets a
//! signature cover it — but that property is only useful if every implementation
//! agrees on those bytes. A test vector is that agreement written down: a specific
//! message and the exact encoding it must produce. If a change to the encoder would
//! alter the bytes, the vector's digest stops matching and the change has to be
//! made deliberately, with the vector updated in the same commit, rather than
//! slipping through and silently breaking every peer built against the old format.
//!
//! Each vector here carries a message and the SHA-256 of its canonical encoding.
//! The tests re-encode each vector and check the digest, confirm the encoding is
//! deterministic and round-trips field for field, and confirm no two distinct
//! vectors collide. The digests are the committed golden values; regenerating them
//! is an explicit act, printed by the generator test below.

const std = @import("std");
const envelope = @import("../schema/envelope.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// One conformance vector: a named message and the digest of its canonical bytes.
pub const Vector = struct {
    name: []const u8,
    message: envelope.Envelope,
    /// SHA-256 of the canonical encoding, as lowercase hex. The golden value.
    digest_hex: []const u8,
};

const sample_key: u128 = 0x0f0e0d0c0b0a09080706050403020100;
const sample_deadline: i64 = 1_767_225_600 * std.time.ns_per_s;

/// The canonical vector set, spanning every message kind so the whole envelope
/// layout is pinned, not just the request path.
pub const vectors = [_]Vector{
    .{
        .name = "request",
        .message = .{
            .version = envelope.current_version,
            .kind = .request,
            .correlation = 7,
            .idempotency_key = sample_key,
            .principal = 0x1111,
            .task = 0x2222,
            .capability = 0x3333,
            .deadline_nanoseconds = sample_deadline,
            .method = "calendar.read",
            .payload = "the request body",
        },
        .digest_hex = "21ab469f29ccfaeffba23ebc1352a8e837853f84dde4e25f96676d317aeaad07",
    },
    .{
        .name = "response",
        .message = .{
            .version = envelope.current_version,
            .kind = .response,
            .correlation = 7,
            .idempotency_key = 0,
            .principal = 0x1111,
            .task = 0x2222,
            .capability = 0,
            .deadline_nanoseconds = 0,
            .method = "calendar.read",
            .payload = "the response body",
        },
        .digest_hex = "991c8dfb0c7eaace982c939b3dff6ccd12e5c62b8690622af3ea23fbed3d0b68",
    },
    .{
        .name = "fault",
        .message = .{
            .version = envelope.current_version,
            .kind = .fault,
            .correlation = 7,
            .idempotency_key = 0,
            .principal = 0x1111,
            .task = 0x2222,
            .capability = 0,
            .deadline_nanoseconds = 0,
            .method = "calendar.read",
            .fault = .unauthorized,
            .payload = "",
        },
        .digest_hex = "79d70b4cb0b565adc09d28e63ac0b3f61f25c71791fc144b17eebd3c1aee467b",
    },
    .{
        .name = "cancel",
        .message = .{
            .version = envelope.current_version,
            .kind = .cancel,
            .correlation = 7,
            .idempotency_key = 0,
            .principal = 0x1111,
            .task = 0x2222,
            .capability = 0,
            .deadline_nanoseconds = 0,
            .method = "",
            .payload = "",
        },
        .digest_hex = "681f761f8682144bc658c5d76fe8a3b563ff32358682e1909ae4ed0eedcbade7",
    },
};

/// Encodes a vector's message and returns the SHA-256 of the canonical bytes.
fn digestOf(vector: Vector, buffer: []u8) [Sha256.digest_length]u8 {
    const encoded = envelope.encode(vector.message, buffer) catch unreachable;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(encoded, &digest, .{});
    return digest;
}

fn hex(digest: [Sha256.digest_length]u8) [Sha256.digest_length * 2]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

test "an older reader accepts a newer-minor message and skips its unknown field" {
    // Encode at the current version, then present it as a newer minor with an
    // extra length-prefixed field the current build does not know. An older
    // reader must accept it, keeping the fields it understands and skipping the
    // rest — the old-reader/new-writer compatibility the versioning promises.
    var base: [envelope.max_message_bytes]u8 = undefined;
    const encoded = try envelope.encode(vectors[0].message, &base);

    var newer: [envelope.max_message_bytes]u8 = undefined;
    @memcpy(newer[0..encoded.len], encoded);
    // Bump the minor version (u16 at offset 6, after protocol and major).
    newer[6] = envelope.current_version.minor + 1;
    // Append an unknown field: a u32 length then that many bytes.
    var cursor = encoded.len;
    std.mem.writeInt(u32, newer[cursor..][0..4], 3, .little);
    cursor += 4;
    @memcpy(newer[cursor..][0..3], &[_]u8{ 0xAA, 0xBB, 0xCC });
    cursor += 3;

    const decoded = try envelope.decode(newer[0..cursor]);
    // The known fields survive unchanged; only the minor rose.
    try std.testing.expectEqual(vectors[0].message.correlation, decoded.correlation);
    try std.testing.expectEqualStrings(vectors[0].message.method, decoded.method);
    try std.testing.expectEqual(@as(u16, envelope.current_version.minor + 1), decoded.version.minor);
}

/// Writes every vector as a language-neutral line — name, hex-encoded canonical
/// bytes, and the golden digest — so a second implementation can diff against the
/// same bytes rather than trusting this one's in-process assertions. This is what
/// makes the vectors shared across runtimes, not merely checked within Zig.
pub fn exportVectors(writer: *std.Io.Writer) (envelope.DecodeError || std.Io.Writer.Error)!void {
    var buffer: [envelope.max_message_bytes]u8 = undefined;
    for (vectors) |vector| {
        const encoded = try envelope.encode(vector.message, &buffer);
        try writer.print("{s} ", .{vector.name});
        for (encoded) |byte| try writer.print("{x:0>2}", .{byte});
        try writer.print(" {s}\n", .{vector.digest_hex});
    }
}

test "the exported vectors are stable and cover every vector" {
    var first: [8192]u8 = undefined;
    var second: [8192]u8 = undefined;
    var writer_first = std.Io.Writer.fixed(&first);
    var writer_second = std.Io.Writer.fixed(&second);
    try exportVectors(&writer_first);
    try exportVectors(&writer_second);

    // Deterministic, and one line per vector so nothing is silently dropped.
    try std.testing.expectEqualStrings(writer_first.buffered(), writer_second.buffered());
    var lines: usize = 0;
    for (writer_first.buffered()) |byte| {
        if (byte == '\n') lines += 1;
    }
    try std.testing.expectEqual(vectors.len, lines);
}

test "malformed messages are rejected with the right error" {
    // A base encoding of a valid request, then targeted corruptions. Each must
    // fail to decode, and with the specific error, so the decoder's rejections
    // are pinned the way the accepted encodings are — a decoder that started
    // accepting one of these would fail here.
    var base: [envelope.max_message_bytes]u8 = undefined;
    const encoded = try envelope.encode(vectors[0].message, &base);
    const len = encoded.len;

    // Wrong protocol identifier (byte 0).
    {
        var bytes = base;
        bytes[0] ^= 0xFF;
        try std.testing.expectError(error.ProtocolMismatch, envelope.decode(bytes[0..len]));
    }
    // Incompatible major version (bytes 4-5).
    {
        var bytes = base;
        bytes[4] = 99;
        try std.testing.expectError(error.IncompatibleVersion, envelope.decode(bytes[0..len]));
    }
    // An undefined message kind (byte 8).
    {
        var bytes = base;
        bytes[8] = 0xFF;
        try std.testing.expectError(error.UnknownEnumeration, envelope.decode(bytes[0..len]));
    }
    // Trailing bytes after a complete message.
    {
        var bytes: [envelope.max_message_bytes + 1]u8 = undefined;
        @memcpy(bytes[0..len], encoded);
        bytes[len] = 0;
        try std.testing.expectError(error.TrailingBytes, envelope.decode(bytes[0 .. len + 1]));
    }
    // A truncated message ends before its fields do.
    {
        if (envelope.decode(encoded[0 .. len - 1])) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "each vector encodes to its committed golden digest" {
    var buffer: [envelope.max_message_bytes]u8 = undefined;
    for (vectors) |vector| {
        const got = hex(digestOf(vector, &buffer));
        std.testing.expectEqualStrings(vector.digest_hex, &got) catch |failure| {
            // A mismatch means either the encoder changed or the golden value is
            // stale. Surface which vector so the fix is unambiguous.
            std.debug.print("vector '{s}' digest is {s}\n", .{ vector.name, &got });
            return failure;
        };
    }
}

test "encoding a vector is deterministic" {
    var first: [envelope.max_message_bytes]u8 = undefined;
    var second: [envelope.max_message_bytes]u8 = undefined;
    for (vectors) |vector| {
        const a = try envelope.encode(vector.message, &first);
        const b = try envelope.encode(vector.message, &second);
        try std.testing.expectEqualSlices(u8, a, b);
    }
}

test "each vector round-trips through decode unchanged" {
    var buffer: [envelope.max_message_bytes]u8 = undefined;
    for (vectors) |vector| {
        const encoded = try envelope.encode(vector.message, &buffer);
        const decoded = try envelope.decode(encoded);
        try std.testing.expectEqual(vector.message.kind, decoded.kind);
        try std.testing.expectEqual(vector.message.correlation, decoded.correlation);
        try std.testing.expectEqual(vector.message.idempotency_key, decoded.idempotency_key);
        try std.testing.expectEqual(vector.message.principal, decoded.principal);
        try std.testing.expectEqual(vector.message.capability, decoded.capability);
        try std.testing.expectEqual(vector.message.fault, decoded.fault);
        try std.testing.expectEqualStrings(vector.message.method, decoded.method);
        try std.testing.expectEqualStrings(vector.message.payload, decoded.payload);
    }
}

test "distinct vectors do not collide" {
    // Different messages must encode to different bytes; a collision would mean the
    // format loses information.
    var buffer_a: [envelope.max_message_bytes]u8 = undefined;
    var buffer_b: [envelope.max_message_bytes]u8 = undefined;
    for (vectors, 0..) |a, i| {
        for (vectors[i + 1 ..]) |b| {
            const da = hex(digestOf(a, &buffer_a));
            const db = hex(digestOf(b, &buffer_b));
            try std.testing.expect(!std.mem.eql(u8, &da, &db));
        }
    }
}
