//! Bounded encoding primitives for the inter-service protocol.
//!
//! Every read is bounds-checked against the remaining input and every length is
//! checked against a declared ceiling before it is used to size anything. A
//! decoder is the first thing an attacker reaches, so it never trusts a length
//! it was given, never allocates proportionally to an unvalidated field, and
//! never reads past what it was handed.
//!
//! Encoding is little-endian and fixed-width. There is no variable-length
//! integer form: the few bytes saved are not worth a decoder path where the
//! length of a length is itself attacker-controlled.

const std = @import("std");

pub const Error = error{
    /// The input ended before the value did.
    Truncated,
    /// A declared length exceeds what the protocol permits.
    LengthExceeded,
    /// A value is outside the range its type allows.
    ValueOutOfRange,
    /// The output buffer cannot hold what is being written.
    BufferTooSmall,
};

/// Reads values from a fixed slice without ever passing its end.
pub const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn remaining(reader: Reader) usize {
        return reader.bytes.len - reader.position;
    }

    pub fn isExhausted(reader: Reader) bool {
        return reader.remaining() == 0;
    }

    fn take(reader: *Reader, count: usize) Error![]const u8 {
        if (count > reader.remaining()) return error.Truncated;
        const slice = reader.bytes[reader.position..][0..count];
        reader.position += count;
        return slice;
    }

    pub fn readU8(reader: *Reader) Error!u8 {
        return (try reader.take(1))[0];
    }

    pub fn readU16(reader: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try reader.take(2))[0..2], .little);
    }

    pub fn readU32(reader: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try reader.take(4))[0..4], .little);
    }

    pub fn readU64(reader: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try reader.take(8))[0..8], .little);
    }

    pub fn readI64(reader: *Reader) Error!i64 {
        return std.mem.readInt(i64, (try reader.take(8))[0..8], .little);
    }

    pub fn readU128(reader: *Reader) Error!u128 {
        return std.mem.readInt(u128, (try reader.take(16))[0..16], .little);
    }

    /// Reads a length-prefixed byte string.
    ///
    /// The declared length is checked against `limit` before it is used, so a
    /// hostile length cannot cause a large read or a large allocation
    /// downstream. The result borrows from the input and lives only as long as
    /// the buffer the reader was given.
    pub fn readBytes(reader: *Reader, limit: usize) Error![]const u8 {
        const length = try reader.readU32();
        if (length > limit) return error.LengthExceeded;
        return reader.take(length);
    }

    /// Skips a field the decoder does not recognize.
    ///
    /// Unknown fields are skipped rather than rejected so a newer minor version
    /// can add fields without breaking an older reader. The length is still
    /// bounded: tolerating an unknown field does not mean tolerating an
    /// unbounded one.
    pub fn skipUnknown(reader: *Reader, limit: usize) Error!void {
        _ = try reader.readBytes(limit);
    }
};

/// Writes values into a caller-provided buffer, never growing it.
pub const Writer = struct {
    buffer: []u8,
    position: usize = 0,

    pub fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    pub fn written(writer: Writer) []const u8 {
        return writer.buffer[0..writer.position];
    }

    fn reserve(writer: *Writer, count: usize) Error![]u8 {
        if (count > writer.buffer.len - writer.position) return error.BufferTooSmall;
        const slice = writer.buffer[writer.position..][0..count];
        writer.position += count;
        return slice;
    }

    pub fn writeU8(writer: *Writer, value: u8) Error!void {
        (try writer.reserve(1))[0] = value;
    }

    pub fn writeU16(writer: *Writer, value: u16) Error!void {
        std.mem.writeInt(u16, (try writer.reserve(2))[0..2], value, .little);
    }

    pub fn writeU32(writer: *Writer, value: u32) Error!void {
        std.mem.writeInt(u32, (try writer.reserve(4))[0..4], value, .little);
    }

    pub fn writeU64(writer: *Writer, value: u64) Error!void {
        std.mem.writeInt(u64, (try writer.reserve(8))[0..8], value, .little);
    }

    pub fn writeI64(writer: *Writer, value: i64) Error!void {
        std.mem.writeInt(i64, (try writer.reserve(8))[0..8], value, .little);
    }

    pub fn writeU128(writer: *Writer, value: u128) Error!void {
        std.mem.writeInt(u128, (try writer.reserve(16))[0..16], value, .little);
    }

    pub fn writeBytes(writer: *Writer, bytes: []const u8, limit: usize) Error!void {
        if (bytes.len > limit) return error.LengthExceeded;
        const length = std.math.cast(u32, bytes.len) orelse return error.LengthExceeded;
        try writer.writeU32(length);
        @memcpy(try writer.reserve(bytes.len), bytes);
    }
};

test "reading past the end reports truncation rather than reading adjacent memory" {
    var reader: Reader = .init(&[_]u8{ 1, 2, 3 });
    _ = try reader.readU16();
    try std.testing.expectError(error.Truncated, reader.readU32());
    try std.testing.expectError(error.Truncated, reader.readU64());
}

test "every fixed-width value round-trips" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeU8(0xab);
    try writer.writeU16(0xbeef);
    try writer.writeU32(0xdeadbeef);
    try writer.writeU64(0x0123456789abcdef);
    try writer.writeI64(-42);
    try writer.writeU128(0xfedcba9876543210fedcba9876543210);

    var reader: Reader = .init(writer.written());
    try std.testing.expectEqual(@as(u8, 0xab), try reader.readU8());
    try std.testing.expectEqual(@as(u16, 0xbeef), try reader.readU16());
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), try reader.readU32());
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), try reader.readU64());
    try std.testing.expectEqual(@as(i64, -42), try reader.readI64());
    try std.testing.expectEqual(
        @as(u128, 0xfedcba9876543210fedcba9876543210),
        try reader.readU128(),
    );
    try std.testing.expect(reader.isExhausted());
}

test "a byte string round-trips within its limit" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeBytes("principal", 32);

    var reader: Reader = .init(writer.written());
    try std.testing.expectEqualStrings("principal", try reader.readBytes(32));
}

test "a declared length beyond the limit is refused before it is used" {
    // A hostile length must not become an allocation size or a read size.
    var buffer: [8]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeU32(0xffff_ffff);

    var reader: Reader = .init(writer.written());
    try std.testing.expectError(error.LengthExceeded, reader.readBytes(64));
}

test "a length within the limit but beyond the input is truncation" {
    var buffer: [8]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeU32(32);

    var reader: Reader = .init(writer.written());
    try std.testing.expectError(error.Truncated, reader.readBytes(64));
}

test "writing beyond the buffer is refused rather than overflowing it" {
    var buffer: [4]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeU32(1);
    try std.testing.expectError(error.BufferTooSmall, writer.writeU8(0));
    try std.testing.expectEqual(@as(usize, 4), writer.written().len);
}

test "writing an oversized string is refused" {
    var buffer: [128]u8 = undefined;
    var writer: Writer = .init(&buffer);
    const long: [64]u8 = @splat('x');
    try std.testing.expectError(error.LengthExceeded, writer.writeBytes(&long, 32));
}

test "an unknown field is skipped without consuming what follows" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeBytes("a field an older reader does not know", 64);
    try writer.writeU32(0x5a5a5a5a);

    var reader: Reader = .init(writer.written());
    try reader.skipUnknown(64);
    try std.testing.expectEqual(@as(u32, 0x5a5a5a5a), try reader.readU32());
    try std.testing.expect(reader.isExhausted());
}

test "an unknown field is still bounded" {
    var buffer: [8]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeU32(1 << 30);

    var reader: Reader = .init(writer.written());
    try std.testing.expectError(error.LengthExceeded, reader.skipUnknown(4096));
}

test "an empty string is distinct from an absent one" {
    var buffer: [16]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeBytes("", 32);

    var reader: Reader = .init(writer.written());
    const value = try reader.readBytes(32);
    try std.testing.expectEqual(@as(usize, 0), value.len);
    try std.testing.expect(reader.isExhausted());
}

test "decoding is deterministic across repeated runs" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeU64(7);
    try writer.writeBytes("capability", 32);

    for (0..8) |_| {
        var reader: Reader = .init(writer.written());
        try std.testing.expectEqual(@as(u64, 7), try reader.readU64());
        try std.testing.expectEqualStrings("capability", try reader.readBytes(32));
    }
}
