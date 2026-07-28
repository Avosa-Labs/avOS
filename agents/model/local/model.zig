//! Describing an on-device model before it is loaded: reading a GGUF file's architecture and the
//! context length it declares, and resolving how much of the local router's window that model can
//! actually serve.
//!
//! The runtime that generates tokens binds separately, but the loader must not hand weights to it
//! blind. Before binding, the platform reads the model's own declaration — which architecture it is,
//! and how long a context it was trained to hold — straight from the GGUF metadata, in pure Zig. That
//! declaration is then reconciled with the router's bound: a request is already capped to the local
//! context window, and a model that was trained for less than that window caps it further. This module
//! is that reconciliation — the honest pre-load check that says what a given model file can serve,
//! independent of any inference library and computed only from the file itself.

const std = @import("std");
const gguf = @import("gguf.zig");
const local = @import("local.zig");

pub const Error = gguf.Error || error{ NoArchitecture, NoContextLength };

/// What a GGUF model declares about itself that the loader needs before binding a runtime: its
/// architecture (borrowed from the file bytes) and the context length it was trained to hold.
pub const Descriptor = struct {
    architecture: []const u8,
    context_length: u32,

    /// The context window this model can actually serve: the smaller of what it declares and what the
    /// local router bounds a request to. A model trained for less than the router window caps the
    /// window to what it can hold; one trained for more is still bounded by the router.
    pub fn servableWindow(desc: Descriptor) u32 {
        return @min(desc.context_length, local.context_window_tokens);
    }

    /// Whether the model can serve the router's full local context window.
    pub fn servesFullWindow(desc: Descriptor) bool {
        return desc.context_length >= local.context_window_tokens;
    }
};

/// Describes a GGUF model from its bytes: its architecture, and the context length it declares under
/// `<architecture>.context_length` — the GGUF convention where the key is namespaced by architecture.
/// Fails with a typed error if either is absent or the wrong kind, so the loader refuses an
/// underspecified model rather than binding a runtime to it.
pub fn describe(bytes: []const u8) Error!Descriptor {
    const arch = (try gguf.architecture(bytes)) orelse return Error.NoArchitecture;

    var key_buf: [128]u8 = undefined;
    const suffix = ".context_length";
    if (arch.len + suffix.len > key_buf.len) return Error.NoContextLength;
    const key = std.fmt.bufPrint(&key_buf, "{s}{s}", .{ arch, suffix }) catch return Error.NoContextLength;

    const value = (try gguf.metadataValue(bytes, key)) orelse return Error.NoContextLength;
    const raw: u64 = switch (value) {
        .unsigned => |u| u,
        else => return Error.NoContextLength,
    };
    const ctx: u32 = if (raw > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(raw);
    return .{ .architecture = arch, .context_length = ctx };
}

// --- Tests ---

const testing = std.testing;

/// Builds a minimal GGUF blob into `buf`: the header, a `general.architecture` string, and a
/// `<arch>.context_length` uint32, and returns the written bytes. Enough to exercise `describe`
/// against real bytes without a model file.
fn buildModel(buf: []u8, arch: []const u8, context_length: u32) []const u8 {
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

    putU32(buf, &pos, gguf.magic);
    putU32(buf, &pos, 3); // version
    putU64(buf, &pos, 0); // tensor_count
    putU64(buf, &pos, 2); // two metadata entries

    putStr(buf, &pos, "general.architecture");
    putU32(buf, &pos, @intFromEnum(gguf.ValueType.string));
    putStr(buf, &pos, arch);

    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}.context_length", .{arch}) catch unreachable;
    putStr(buf, &pos, key);
    putU32(buf, &pos, @intFromEnum(gguf.ValueType.uint32));
    putU32(buf, &pos, context_length);

    return buf[0..pos];
}

test "a model that declares more than the router window serves the full window" {
    var buf: [256]u8 = undefined;
    const blob = buildModel(&buf, "llama", 8192);
    const desc = try describe(blob);
    try testing.expectEqualStrings("llama", desc.architecture);
    try testing.expectEqual(@as(u32, 8192), desc.context_length);
    try testing.expect(desc.servesFullWindow());
    try testing.expectEqual(local.context_window_tokens, desc.servableWindow());
}

test "a model that declares less than the router window caps the window it can serve" {
    var buf: [256]u8 = undefined;
    const blob = buildModel(&buf, "phi", 2048);
    const desc = try describe(blob);
    try testing.expectEqualStrings("phi", desc.architecture);
    try testing.expect(!desc.servesFullWindow());
    // The servable window is the model's own limit, below the router's 4096.
    try testing.expectEqual(@as(u32, 2048), desc.servableWindow());
}

test "a model missing its architecture or context length is a typed error" {
    // No metadata at all: architecture is absent.
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], gguf.magic, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 3, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], 0, .little); // tensor_count
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], 0, .little); // no metadata
    pos += 8;
    try testing.expectError(Error.NoArchitecture, describe(buf[0..pos]));
}
