//! The engine-pin gate: every pinned C engine is fully accounted for.
//!
//! The graphics rebuild's engines — the GPU API, and later the raster and text libraries —
//! are dependencies behind Zig adapters, pinned exactly like the toolchain. `engines.lock.json`
//! records each one; this gate holds that manifest to the rule so a pin cannot enter loose. For
//! every engine it requires a source on the project's own host, a SHA-256 digest, a resolved
//! commit, an SPDX licence, the adapter it sits behind, and an architecture decision record that
//! actually exists on disk. A pin missing any of these fails the build — which is what keeps
//! "pinned exactly, decided deliberately" an enforceable claim rather than a intention.
//!
//! It reads the committed manifest, not the network: re-resolving a pin from upstream is
//! `version-lock`'s job. This checks that what is committed is complete and internally sound,
//! so it runs on every machine.
//!
//! Exit codes: 0 every engine accounted for, 1 an incomplete or unsound pin, 3 the manifest is
//! missing or malformed.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

const manifest_path = "engines.lock.json";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buf);
    const out = &out_file.interface;

    const text = io_adapters.cwd().readFileAlloc(io, manifest_path, gpa, .limited(4 * 1024 * 1024)) catch {
        try out.print("engine-lock: {s} missing\n", .{manifest_path});
        try out.flush();
        return 3;
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch {
        try out.print("engine-lock: {s} is not valid JSON\n", .{manifest_path});
        try out.flush();
        return 3;
    };

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try out.print("engine-lock: {s} is not an object\n", .{manifest_path});
            try out.flush();
            return 3;
        },
    };

    if (nonEmptyString(root.get("selection_rule")) == null or nonEmptyString(root.get("generated_at")) == null) {
        try out.print("engine-lock: {s} lacks a selection_rule or generated_at\n", .{manifest_path});
        try out.flush();
        return 3;
    }

    const engines = switch (root.get("engines") orelse .null) {
        .array => |array| array,
        else => {
            try out.print("engine-lock: {s} has no engines array\n", .{manifest_path});
            try out.flush();
            return 3;
        },
    };
    if (engines.items.len == 0) {
        try out.print("engine-lock: {s} pins no engines\n", .{manifest_path});
        try out.flush();
        return 3;
    }

    var violations: usize = 0;
    for (engines.items) |item| {
        const engine = switch (item) {
            .object => |object| object,
            else => {
                try out.print("engine-lock: a malformed engine entry\n", .{});
                violations += 1;
                continue;
            },
        };
        const name = nonEmptyString(engine.get("name")) orelse "?";
        violations += try checkEngine(out, io, arena, name, engine);
    }

    if (violations != 0) {
        try out.print("engine-lock: {d} unsound pin(s)\n", .{violations});
        try out.flush();
        return 1;
    }
    try out.print("engine-lock: {d} engine(s) pinned, each with source, digest, licence, adapter, and ADR\n", .{engines.items.len});
    try out.flush();
    return 0;
}

/// Checks one engine and returns how many rules it broke, reporting each.
fn checkEngine(out: anytype, io: std.Io, arena: std.mem.Allocator, name: []const u8, engine: std.json.ObjectMap) !usize {
    var broken: usize = 0;

    // The plain required fields.
    inline for (.{ "name", "role", "purpose", "version", "license", "adapter" }) |field| {
        if (nonEmptyString(engine.get(field)) == null) {
            try out.print("engine-lock: {s}: missing {s}\n", .{ name, field });
            broken += 1;
        }
    }

    // The commit and digest are fixed-width hex.
    if (!isHex(nonEmptyString(engine.get("commit")) orelse "", 40)) {
        try out.print("engine-lock: {s}: commit is not a 40-hex object id\n", .{name});
        broken += 1;
    }
    if (!isHex(nonEmptyString(engine.get("sha256")) orelse "", 64)) {
        try out.print("engine-lock: {s}: sha256 is not a 64-hex digest\n", .{name});
        broken += 1;
    }

    // The archive must come from the project's own host, not an aggregator or mirror.
    const upstream = nonEmptyString(engine.get("upstream")) orelse "";
    const source = nonEmptyString(engine.get("source")) orelse "";
    if (!std.mem.startsWith(u8, upstream, "https://") or !std.mem.startsWith(u8, source, "https://")) {
        try out.print("engine-lock: {s}: upstream and source must be https URLs\n", .{name});
        broken += 1;
    } else if (!sameHost(upstream, source)) {
        try out.print("engine-lock: {s}: source host does not match upstream\n", .{name});
        broken += 1;
    }

    // The ADR must be named and must exist.
    const adr = nonEmptyString(engine.get("adr")) orelse "";
    if (adr.len == 0) {
        try out.print("engine-lock: {s}: no ADR recorded\n", .{name});
        broken += 1;
    } else if (io_adapters.cwd().readFileAlloc(io, adr, arena, .limited(1 << 20))) |_| {} else |_| {
        try out.print("engine-lock: {s}: ADR {s} does not exist\n", .{ name, adr });
        broken += 1;
    }

    return broken;
}

/// The string value of a JSON node, or null when it is absent, not a string, or empty.
fn nonEmptyString(node: ?std.json.Value) ?[]const u8 {
    const value = node orelse return null;
    return switch (value) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

/// Whether `text` is exactly `len` lowercase-or-uppercase hexadecimal digits.
fn isHex(text: []const u8, len: usize) bool {
    if (text.len != len) return false;
    for (text) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// The host of an `https://host/...` URL: the span between the scheme and the next slash.
fn hostOf(url: []const u8) []const u8 {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return "";
    const rest = url[scheme.len..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..end];
}

/// Whether two URLs share a host — the archive must come from the project's own host.
fn sameHost(a: []const u8, b: []const u8) bool {
    const ha = hostOf(a);
    return ha.len != 0 and std.mem.eql(u8, ha, hostOf(b));
}

// --- Tests ---

const testing = std.testing;

test "isHex accepts exact-width hex and rejects everything else" {
    try testing.expect(isHex("8864cdc896bbc2a9b6eb36b3218fc9ef57908d77", 40));
    try testing.expect(isHex("6d1bb65e49520344cc0a48af3dc02e993781efff14c7ebdcb8ae9fa23ddf7e83", 64));
    try testing.expect(!isHex("8864cdc", 40)); // too short
    try testing.expect(!isHex("g864cdc896bbc2a9b6eb36b3218fc9ef57908d77", 40)); // non-hex digit
    try testing.expect(!isHex("", 64));
}

test "hostOf and sameHost read the URL host" {
    try testing.expectEqualStrings("github.com", hostOf("https://github.com/KhronosGroup/Vulkan-Headers"));
    try testing.expect(sameHost(
        "https://github.com/KhronosGroup/Vulkan-Headers",
        "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-1.4.350.1.tar.gz",
    ));
    try testing.expect(!sameHost(
        "https://github.com/KhronosGroup/Vulkan-Headers",
        "https://mirror.example.com/vulkan.tar.gz",
    )); // a mirror is refused
    try testing.expect(!sameHost("http://github.com/x", "https://github.com/x")); // non-https host is empty
}

test "nonEmptyString distinguishes present, empty, and non-string" {
    try testing.expect(nonEmptyString(.{ .string = "x" }) != null);
    try testing.expect(nonEmptyString(.{ .string = "" }) == null);
    try testing.expect(nonEmptyString(.{ .integer = 3 }) == null);
    try testing.expect(nonEmptyString(null) == null);
}
