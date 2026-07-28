//! Reading a GGUF model file's header and metadata — the format every open-weights model the local
//! runtime loads is shipped in, parsed in pure Zig so the platform understands its own weights.
//!
//! Before an on-device model can run, its file must be understood: GGUF puts a small header up front
//! (a magic, a version, how many tensors and how many metadata entries follow) and then a table of
//! metadata key-values that name the architecture, the context length, the tokenizer, and everything
//! else a loader needs before it touches a single weight. This module reads that header and walks that
//! metadata table exactly and safely — every field is bounds-checked against the file, a short or
//! malformed file is a typed error rather than a crash, and no weight data is dereferenced here. It is
//! the honest front door to a real model file, independent of any inference library: the runtime binds
//! separately, but the platform can parse, validate, and describe a GGUF model on its own.

const std = @import("std");

/// The GGUF magic, the ASCII bytes "GGUF" read as a little-endian u32.
pub const magic: u32 = 0x46554747;

/// The header that opens every GGUF file.
pub const Header = struct {
    version: u32,
    tensor_count: u64,
    metadata_kv_count: u64,
};

/// The type of a metadata value, as GGUF encodes it.
pub const ValueType = enum(u32) {
    uint8 = 0,
    int8 = 1,
    uint16 = 2,
    int16 = 3,
    uint32 = 4,
    int32 = 5,
    float32 = 6,
    bool = 7,
    string = 8,
    array = 9,
    uint64 = 10,
    int64 = 11,
    float64 = 12,
    _,
};

pub const Error = error{ BadMagic, UnsupportedVersion, Truncated, BadValueType };

/// The fixed byte width of a scalar value type, or null for the variable-length kinds (string, array).
fn scalarWidth(vt: ValueType) ?usize {
    return switch (vt) {
        .uint8, .int8, .bool => 1,
        .uint16, .int16 => 2,
        .uint32, .int32, .float32 => 4,
        .uint64, .int64, .float64 => 8,
        .string, .array => null,
        else => null,
    };
}

/// A cursor over a GGUF file that reads its header on init and then walks the metadata table.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize,
    header: Header,

    /// Reads and validates the header. Fails on a wrong magic, an unsupported version, or a file too
    /// short to hold the header.
    pub fn init(bytes: []const u8) Error!Reader {
        var reader = Reader{ .bytes = bytes, .pos = 0, .header = undefined };
        if (try reader.readU32() != magic) return Error.BadMagic;
        const version = try reader.readU32();
        if (version < 2 or version > 3) return Error.UnsupportedVersion;
        const tensor_count = try reader.readU64();
        const metadata_kv_count = try reader.readU64();
        reader.header = .{ .version = version, .tensor_count = tensor_count, .metadata_kv_count = metadata_kv_count };
        return reader;
    }

    fn take(reader: *Reader, n: usize) Error![]const u8 {
        if (reader.pos + n > reader.bytes.len) return Error.Truncated;
        const slice = reader.bytes[reader.pos .. reader.pos + n];
        reader.pos += n;
        return slice;
    }

    fn readU32(reader: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try reader.take(4))[0..4], .little);
    }

    fn readU64(reader: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try reader.take(8))[0..8], .little);
    }

    /// Reads a GGUF string: a u64 length followed by that many bytes. The slice borrows the file.
    fn readString(reader: *Reader) Error![]const u8 {
        const len = try reader.readU64();
        return reader.take(@intCast(len));
    }

    /// Skips a value of a given type, advancing the cursor past it. A fixed scalar advances its width;
    /// a string advances its length; an array advances its element type, count, and each element.
    fn skipValue(reader: *Reader, vt: ValueType) Error!void {
        if (scalarWidth(vt)) |w| {
            _ = try reader.take(w);
            return;
        }
        switch (vt) {
            .string => _ = try reader.readString(),
            .array => {
                const elem: ValueType = @enumFromInt(try reader.readU32());
                const n = try reader.readU64();
                var i: u64 = 0;
                while (i < n) : (i += 1) try reader.skipValue(elem);
            },
            else => return Error.BadValueType,
        }
    }

    /// A metadata entry: its key and value type. The value is skipped; a caller wanting it reads from
    /// the file at the recorded position through the typed accessors (future work), but the walk is
    /// exact so keys and their types are always correct.
    pub const Entry = struct { key: []const u8, value_type: ValueType };

    /// Reads the next metadata entry, or null when the declared count is exhausted. Must be called in
    /// sequence after init; it advances the cursor past each value so the table is walked exactly.
    pub fn nextMetadata(reader: *Reader, remaining: *u64) Error!?Entry {
        if (remaining.* == 0) return null;
        const key = try reader.readString();
        const vt: ValueType = @enumFromInt(try reader.readU32());
        try reader.skipValue(vt);
        remaining.* -= 1;
        return Entry{ .key = key, .value_type = vt };
    }

    /// A decoded metadata value. The kinds a loader actually reads are decoded; anything else is
    /// walked past and reported as `other`, so the caller sees the type without a raw byte blob.
    pub const Value = union(enum) {
        unsigned: u64,
        signed: i64,
        string: []const u8,
        boolean: bool,
        other: void,
    };

    /// Reads a value of a given type at the cursor, decoding the kinds a loader reads and skipping the
    /// rest.
    fn readValue(reader: *Reader, vt: ValueType) Error!Value {
        return switch (vt) {
            .uint8 => .{ .unsigned = (try reader.take(1))[0] },
            .int8 => .{ .signed = @as(i8, @bitCast((try reader.take(1))[0])) },
            .uint16 => .{ .unsigned = std.mem.readInt(u16, (try reader.take(2))[0..2], .little) },
            .int16 => .{ .signed = std.mem.readInt(i16, (try reader.take(2))[0..2], .little) },
            .uint32 => .{ .unsigned = try reader.readU32() },
            .int32 => .{ .signed = std.mem.readInt(i32, (try reader.take(4))[0..4], .little) },
            .uint64 => .{ .unsigned = try reader.readU64() },
            .int64 => .{ .signed = std.mem.readInt(i64, (try reader.take(8))[0..8], .little) },
            .bool => .{ .boolean = (try reader.take(1))[0] != 0 },
            .string => .{ .string = try reader.readString() },
            else => blk: {
                try reader.skipValue(vt);
                break :blk .other;
            },
        };
    }
};

/// Finds a metadata value by key, decoding it, or null if the key is absent. Reads the table from the
/// start each call — the loader reads a handful of keys, so this stays simple and exact.
pub fn metadataValue(bytes: []const u8, key: []const u8) Error!?Reader.Value {
    var reader = try Reader.init(bytes);
    var remaining = reader.header.metadata_kv_count;
    while (remaining > 0) : (remaining -= 1) {
        const k = try reader.readString();
        const vt: ValueType = @enumFromInt(try reader.readU32());
        const v = try reader.readValue(vt);
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

/// The model architecture a GGUF declares (e.g. "llama"), read from `general.architecture`, or null if
/// it is absent or not a string.
pub fn architecture(bytes: []const u8) Error!?[]const u8 {
    const value = (try metadataValue(bytes, "general.architecture")) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

// --- Tests ---

const testing = std.testing;

/// Builds a minimal valid GGUF blob in `buf`: the header plus `keys` metadata entries, each a string
/// value, and returns the written bytes. A tiny writer so the reader is tested against real bytes.
fn buildGguf(buf: []u8, version: u32, tensor_count: u64, keys: []const [2][]const u8) []const u8 {
    var pos: usize = 0;
    const putU32 = struct {
        fn f(b: []u8, p: *usize, v: u32) void {
            std.mem.writeInt(u32, b[p.*..][0..4], v, .little);
            p.* += 4;
        }
    }.f;
    const putU64 = struct {
        fn f(b: []u8, p: *usize, v: u64) void {
            std.mem.writeInt(u64, b[p.*..][0..8], v, .little);
            p.* += 8;
        }
    }.f;
    const putStr = struct {
        fn f(b: []u8, p: *usize, s: []const u8) void {
            std.mem.writeInt(u64, b[p.*..][0..8], s.len, .little);
            p.* += 8;
            @memcpy(b[p.*..][0..s.len], s);
            p.* += s.len;
        }
    }.f;
    putU32(buf, &pos, magic);
    putU32(buf, &pos, version);
    putU64(buf, &pos, tensor_count);
    putU64(buf, &pos, keys.len);
    for (keys) |kv| {
        putStr(buf, &pos, kv[0]); // key
        putU32(buf, &pos, @intFromEnum(ValueType.string)); // value type
        putStr(buf, &pos, kv[1]); // string value
    }
    return buf[0..pos];
}

test "the header is read and validated" {
    var buf: [256]u8 = undefined;
    const blob = buildGguf(&buf, 3, 42, &.{});
    const reader = try Reader.init(blob);
    try testing.expectEqual(@as(u32, 3), reader.header.version);
    try testing.expectEqual(@as(u64, 42), reader.header.tensor_count);
    try testing.expectEqual(@as(u64, 0), reader.header.metadata_kv_count);
}

test "a wrong magic, a bad version, and a short file are typed errors" {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0xDEADBEEF, .little);
    try testing.expectError(Error.BadMagic, Reader.init(&buf));
    // Valid magic, version 99.
    var v = buf;
    std.mem.writeInt(u32, v[0..4], magic, .little);
    std.mem.writeInt(u32, v[4..8], 99, .little);
    std.mem.writeInt(u64, v[8..16], 0, .little);
    try testing.expectError(Error.UnsupportedVersion, Reader.init(&v));
    // Too short to even hold the header.
    try testing.expectError(Error.Truncated, Reader.init(v[0..6]));
}

test "the metadata table is walked exactly, keys and types correct" {
    var buf: [256]u8 = undefined;
    const blob = buildGguf(&buf, 3, 0, &.{
        .{ "general.architecture", "llama" },
        .{ "general.name", "test-model" },
    });
    var reader = try Reader.init(blob);
    var remaining = reader.header.metadata_kv_count;
    const first = (try reader.nextMetadata(&remaining)).?;
    try testing.expectEqualStrings("general.architecture", first.key);
    try testing.expectEqual(ValueType.string, first.value_type);
    const second = (try reader.nextMetadata(&remaining)).?;
    try testing.expectEqualStrings("general.name", second.key);
    // The table is exhausted exactly at the declared count.
    try testing.expect((try reader.nextMetadata(&remaining)) == null);
}

test "typed metadata values are read back by key, including the architecture" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], magic, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 3, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], 0, .little); // tensor_count
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], 2, .little); // two metadata entries
    pos += 8;
    // "general.architecture" = string "llama"
    const k1 = "general.architecture";
    std.mem.writeInt(u64, buf[pos..][0..8], k1.len, .little);
    pos += 8;
    @memcpy(buf[pos..][0..k1.len], k1);
    pos += k1.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intFromEnum(ValueType.string), .little);
    pos += 4;
    const arch = "llama";
    std.mem.writeInt(u64, buf[pos..][0..8], arch.len, .little);
    pos += 8;
    @memcpy(buf[pos..][0..arch.len], arch);
    pos += arch.len;
    // "llama.context_length" = uint32 4096
    const k2 = "llama.context_length";
    std.mem.writeInt(u64, buf[pos..][0..8], k2.len, .little);
    pos += 8;
    @memcpy(buf[pos..][0..k2.len], k2);
    pos += k2.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intFromEnum(ValueType.uint32), .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 4096, .little);
    pos += 4;

    const blob = buf[0..pos];
    try testing.expectEqualStrings("llama", (try architecture(blob)).?);
    const ctx = (try metadataValue(blob, "llama.context_length")).?;
    try testing.expectEqual(@as(u64, 4096), ctx.unsigned);
    // A missing key is null, not an error.
    try testing.expect((try metadataValue(blob, "nonexistent")) == null);
}

test "an array-valued metadata entry is skipped without misreading the rest" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], magic, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 3, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], 0, .little); // tensor_count
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], 2, .little); // two metadata entries
    pos += 8;
    // Entry 1: key "dims", array of two uint32.
    const k1 = "dims";
    std.mem.writeInt(u64, buf[pos..][0..8], k1.len, .little);
    pos += 8;
    @memcpy(buf[pos..][0..k1.len], k1);
    pos += k1.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intFromEnum(ValueType.array), .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], @intFromEnum(ValueType.uint32), .little); // element type
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], 2, .little); // count
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], 4096, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 11008, .little);
    pos += 4;
    // Entry 2: key "ok", string "yes".
    const k2 = "ok";
    std.mem.writeInt(u64, buf[pos..][0..8], k2.len, .little);
    pos += 8;
    @memcpy(buf[pos..][0..k2.len], k2);
    pos += k2.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intFromEnum(ValueType.string), .little);
    pos += 4;
    const answer = "yes";
    std.mem.writeInt(u64, buf[pos..][0..8], answer.len, .little);
    pos += 8;
    @memcpy(buf[pos..][0..answer.len], answer);
    pos += answer.len;

    var reader = try Reader.init(buf[0..pos]);
    var remaining = reader.header.metadata_kv_count;
    const first = (try reader.nextMetadata(&remaining)).?;
    try testing.expectEqualStrings("dims", first.key);
    try testing.expectEqual(ValueType.array, first.value_type);
    // The array was skipped exactly, so the second entry reads correctly.
    const second = (try reader.nextMetadata(&remaining)).?;
    try testing.expectEqualStrings("ok", second.key);
}
