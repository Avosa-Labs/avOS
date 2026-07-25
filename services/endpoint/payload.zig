//! A minimal fixed-field reader and writer for service request and response
//! payloads, so a handler decodes the bytes an envelope carries without a parser
//! and encodes its reply the same way on both ends.
//!
//! The envelope pins the message frame — who sent it, under what capability, to
//! which method — but its payload is opaque bytes each service interprets for
//! itself. Most service payloads are a handful of fixed-width fields: an
//! identifier, an amount, a flag. This gives them one small, total codec rather
//! than a bespoke parse in every handler. It is deliberately not a general
//! serializer: every read is length-checked and returns an error rather than
//! reading past the buffer, so a truncated or hostile payload is a typed refusal,
//! never an out-of-bounds read. Values are little-endian, matching the envelope's
//! own encoding so the whole message reads one way.

const std = @import("std");

pub const Error = error{
    /// A read asked for more bytes than the payload holds.
    Truncated,
    /// A write asked for more room than the buffer holds.
    Overflow,
};

/// Reads fixed-width fields from a payload, refusing to read past its end.
pub const Reader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    fn take(reader: *Reader, count: usize) Error![]const u8 {
        if (reader.cursor + count > reader.bytes.len) return error.Truncated;
        const slice = reader.bytes[reader.cursor .. reader.cursor + count];
        reader.cursor += count;
        return slice;
    }

    pub fn u8_(reader: *Reader) Error!u8 {
        const slice = try reader.take(1);
        return slice[0];
    }

    pub fn boolean(reader: *Reader) Error!bool {
        return (try reader.u8_()) != 0;
    }

    pub fn u64_(reader: *Reader) Error!u64 {
        const slice = try reader.take(8);
        return std.mem.readInt(u64, slice[0..8], .little);
    }

    pub fn u128_(reader: *Reader) Error!u128 {
        const slice = try reader.take(16);
        return std.mem.readInt(u128, slice[0..16], .little);
    }

    /// Whether every byte has been consumed. A handler that expects a fixed payload
    /// checks this so trailing bytes are rejected rather than ignored.
    pub fn atEnd(reader: Reader) bool {
        return reader.cursor == reader.bytes.len;
    }
};

/// Writes fixed-width fields into a caller-owned buffer, refusing to overrun it.
pub const Writer = struct {
    buffer: []u8,
    cursor: usize = 0,

    pub fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    fn room(writer: *Writer, count: usize) Error![]u8 {
        if (writer.cursor + count > writer.buffer.len) return error.Overflow;
        const slice = writer.buffer[writer.cursor .. writer.cursor + count];
        writer.cursor += count;
        return slice;
    }

    pub fn putU8(writer: *Writer, value: u8) Error!void {
        const slice = try writer.room(1);
        slice[0] = value;
    }

    pub fn putBool(writer: *Writer, value: bool) Error!void {
        try writer.putU8(if (value) 1 else 0);
    }

    pub fn putU64(writer: *Writer, value: u64) Error!void {
        const slice = try writer.room(8);
        std.mem.writeInt(u64, slice[0..8], value, .little);
    }

    pub fn putU128(writer: *Writer, value: u128) Error!void {
        const slice = try writer.room(16);
        std.mem.writeInt(u128, slice[0..16], value, .little);
    }

    /// The bytes written so far, for handing to a reply.
    pub fn written(writer: Writer) []const u8 {
        return writer.buffer[0..writer.cursor];
    }
};

// --- Tests ---

test "a value round-trips through write and read" {
    var buffer: [64]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.putU128(0xDEAD_BEEF);
    try writer.putU64(42);
    try writer.putBool(true);

    var reader = Reader.init(writer.written());
    try std.testing.expectEqual(@as(u128, 0xDEAD_BEEF), try reader.u128_());
    try std.testing.expectEqual(@as(u64, 42), try reader.u64_());
    try std.testing.expectEqual(true, try reader.boolean());
    try std.testing.expect(reader.atEnd());
}

test "reading past the end is a truncation error, not an overread" {
    var reader = Reader.init(&[_]u8{ 1, 2, 3 });
    try std.testing.expectError(error.Truncated, reader.u64_());
}

test "writing past the buffer is an overflow error" {
    var buffer: [4]u8 = undefined;
    var writer = Writer.init(&buffer);
    try std.testing.expectError(error.Overflow, writer.putU64(1));
}

test "trailing bytes are visible so a handler can reject them" {
    var reader = Reader.init(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 9 });
    _ = try reader.u64_();
    try std.testing.expect(!reader.atEnd()); // one byte remains
}
