//! Turning values into bytes one way, so the same value always becomes the same
//! bytes.
//!
//! Anything the platform signs, hashes, or compares as bytes must encode
//! canonically: one value, one encoding, no choices. The moment a value has two
//! valid byte forms, a signature over one does not cover the other, two equal
//! things hash differently, and a comparison that should say "same" says
//! "different". So this module offers no options — no endianness to pick, no
//! padding to vary, no order to choose. It writes a value the one way, and reads
//! bytes back checking that they were written that way, rejecting a second
//! encoding of the same value rather than accepting it.
//!
//! Integers are fixed-width little-endian, and variable-length data is length-
//! prefixed. Both are the plainest choices, made once here so that everything
//! above — packages, images, ledgers, wire messages — inherits the same
//! discipline instead of each reinventing it slightly differently.

const std = @import("std");

pub const Error = error{
    /// The buffer cannot hold what is being written, or does not hold what is
    /// being read.
    ShortBuffer,
    /// A length prefix claims more bytes than remain.
    LengthExceedsInput,
    /// Trailing bytes remained after decoding what was expected. A canonical
    /// encoding has no slack, so leftover bytes mean the input was not what it
    /// claimed.
    TrailingBytes,
};

/// Writes bytes into a fixed buffer, tracking the position.
pub const Writer = struct {
    buffer: []u8,
    position: usize = 0,

    pub fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    /// The bytes written so far.
    pub fn written(writer: Writer) []const u8 {
        return writer.buffer[0..writer.position];
    }

    fn reserve(writer: *Writer, count: usize) Error![]u8 {
        if (writer.position + count > writer.buffer.len) return error.ShortBuffer;
        const slice = writer.buffer[writer.position .. writer.position + count];
        writer.position += count;
        return slice;
    }

    /// Writes an unsigned integer as fixed-width little-endian.
    ///
    /// Fixed width rather than minimal, because a minimal encoding gives the same
    /// value two forms — three and three-with-a-leading-zero — and canonical
    /// means one.
    pub fn writeInt(writer: *Writer, comptime T: type, value: T) Error!void {
        const slice = try writer.reserve(@sizeOf(T));
        std.mem.writeInt(T, slice[0..@sizeOf(T)], value, .little);
    }

    /// Writes a byte string prefixed with its length as a u32.
    ///
    /// The length goes first and is fixed-width, so a reader knows exactly how
    /// many bytes follow without scanning for a terminator that could appear in
    /// the data.
    pub fn writeBytes(writer: *Writer, bytes: []const u8) Error!void {
        const length = std.math.cast(u32, bytes.len) orelse return error.ShortBuffer;
        try writer.writeInt(u32, length);
        const slice = try writer.reserve(bytes.len);
        @memcpy(slice, bytes);
    }

    /// Writes a boolean as a single byte, 0 or 1, never any other value.
    pub fn writeBool(writer: *Writer, value: bool) Error!void {
        try writer.writeInt(u8, @intFromBool(value));
    }
};

/// Reads bytes from a fixed buffer, tracking the position and rejecting
/// non-canonical input.
pub const Reader = struct {
    buffer: []const u8,
    position: usize = 0,

    pub fn init(buffer: []const u8) Reader {
        return .{ .buffer = buffer };
    }

    fn take(reader: *Reader, count: usize) Error![]const u8 {
        if (reader.position + count > reader.buffer.len) return error.ShortBuffer;
        const slice = reader.buffer[reader.position .. reader.position + count];
        reader.position += count;
        return slice;
    }

    pub fn readInt(reader: *Reader, comptime T: type) Error!T {
        const slice = try reader.take(@sizeOf(T));
        return std.mem.readInt(T, slice[0..@sizeOf(T)], .little);
    }

    /// Reads a length-prefixed byte string, returning a view into the input.
    pub fn readBytes(reader: *Reader) Error![]const u8 {
        const length = try reader.readInt(u32);
        if (reader.position + length > reader.buffer.len) return error.LengthExceedsInput;
        return reader.take(length);
    }

    /// Reads a boolean, rejecting any byte other than 0 or 1.
    ///
    /// A canonical boolean has exactly two encodings. Accepting 2 as true would
    /// mean true had many forms, and a signature over one would not cover
    /// another.
    pub fn readBool(reader: *Reader) Error!bool {
        const byte = try reader.readInt(u8);
        return switch (byte) {
            0 => false,
            1 => true,
            else => error.TrailingBytes,
        };
    }

    /// Whether every byte has been consumed.
    ///
    /// A canonical decode consumes exactly its input. Leftover bytes mean the
    /// input carried more than the value it claimed to be.
    pub fn atEnd(reader: *const Reader) bool {
        return reader.position == reader.buffer.len;
    }

    /// Asserts the input was fully consumed, rejecting trailing bytes.
    pub fn finish(reader: *const Reader) Error!void {
        if (!reader.atEnd()) return error.TrailingBytes;
    }
};

test "an integer round-trips through the same bytes" {
    var buffer: [8]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeInt(u64, 0x0123_4567_89ab_cdef);

    var reader: Reader = .init(writer.written());
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), try reader.readInt(u64));
    try reader.finish();
}

test "integers are little-endian, which is the one chosen order" {
    var buffer: [4]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeInt(u32, 1);
    // The single canonical byte layout: least significant byte first.
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, writer.written());
}

test "a byte string round-trips with its length" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeBytes("hello");
    try writer.writeBytes("");

    var reader: Reader = .init(writer.written());
    try std.testing.expectEqualStrings("hello", try reader.readBytes());
    try std.testing.expectEqualStrings("", try reader.readBytes());
    try reader.finish();
}

test "the same value always encodes to the same bytes" {
    // The property the whole module exists for: encoding is a function, so equal
    // values give equal bytes and a signature over one covers the other.
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    var writer_a: Writer = .init(&first);
    var writer_b: Writer = .init(&second);
    inline for (.{ &writer_a, &writer_b }) |writer| {
        try writer.writeInt(u32, 42);
        try writer.writeBytes("record");
        try writer.writeBool(true);
    }
    try std.testing.expectEqualSlices(u8, writer_a.written(), writer_b.written());
}

test "a boolean rejects any byte but zero or one" {
    // Accepting 2 as true would give true many encodings.
    var reader: Reader = .init(&.{2});
    try std.testing.expectError(error.TrailingBytes, reader.readBool());

    var zero: Reader = .init(&.{0});
    try std.testing.expectEqual(false, try zero.readBool());
    var one: Reader = .init(&.{1});
    try std.testing.expectEqual(true, try one.readBool());
}

test "trailing bytes are rejected" {
    var buffer: [8]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeInt(u16, 5);

    // The written value plus an extra byte: not a canonical encoding of a single
    // u16, and finish must say so.
    var padded: [4]u8 = undefined;
    @memcpy(padded[0..2], writer.written());
    padded[2] = 0;
    padded[3] = 0;

    var reader: Reader = .init(&padded);
    _ = try reader.readInt(u16);
    try std.testing.expectError(error.TrailingBytes, reader.finish());
}

test "a length prefix longer than the input is rejected" {
    // A u32 length of 100 followed by no data: a decoder that trusted the length
    // would read past the buffer.
    var reader: Reader = .init(&.{ 100, 0, 0, 0 });
    try std.testing.expectError(error.LengthExceedsInput, reader.readBytes());
}

test "writing past the buffer is refused, not overrun" {
    var buffer: [2]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try std.testing.expectError(error.ShortBuffer, writer.writeInt(u32, 1));
}

test "reading past the buffer is refused" {
    var reader: Reader = .init(&.{ 1, 2 });
    try std.testing.expectError(error.ShortBuffer, reader.readInt(u32));
}

test "a full message of mixed fields round-trips exactly" {
    var buffer: [128]u8 = undefined;
    var writer: Writer = .init(&buffer);
    try writer.writeInt(u8, 7);
    try writer.writeBytes("principal");
    try writer.writeInt(u64, 0xdead_beef);
    try writer.writeBool(false);

    var reader: Reader = .init(writer.written());
    try std.testing.expectEqual(@as(u8, 7), try reader.readInt(u8));
    try std.testing.expectEqualStrings("principal", try reader.readBytes());
    try std.testing.expectEqual(@as(u64, 0xdead_beef), try reader.readInt(u64));
    try std.testing.expectEqual(false, try reader.readBool());
    try reader.finish();
}

test "the empty input decodes to nothing and is at its end" {
    var reader: Reader = .init(&.{});
    try std.testing.expect(reader.atEnd());
    try reader.finish();
}
