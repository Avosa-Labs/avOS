//! Vendors the pinned graphics engines: fetch, verify against the pin, unpack.
//!
//! `engines.lock.json` records each engine's upstream archive and its SHA-256; the
//! `engine-lock` gate proves that record is complete. This is the step that acts on it — it
//! fetches each archive from the pinned source, hashes what it received, and refuses to
//! proceed unless the digest is exactly the one recorded, so a substituted or corrupted
//! archive never reaches the tree. A verified archive is unpacked into `.engines/<name>`, the
//! local cache the device adapters build against. Nothing is committed; the cache is rebuilt
//! from the pin on any machine.
//!
//! It is opt-in — run `zig build vendor-engines` — and not part of the gate set, so ordinary
//! builds and CI stay offline. The digest is the trust boundary: fetching is only ever
//! allowed to place bytes that match the committed pin.
//!
//! Exit codes: 0 every engine vendored and verified, 1 a digest mismatch or fetch failure,
//! 3 the manifest is missing or malformed.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

const flate = std.compress.flate;
const tar = std.tar;

const manifest_path = "engines.lock.json";
const cache_root = ".engines";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buf);
    const out = &out_file.interface;

    const text = io_adapters.cwd().readFileAlloc(io, manifest_path, gpa, .limited(4 * 1024 * 1024)) catch {
        try out.print("vendor-engines: {s} missing\n", .{manifest_path});
        try out.flush();
        return 3;
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch {
        try out.print("vendor-engines: {s} is not valid JSON\n", .{manifest_path});
        try out.flush();
        return 3;
    };
    const engines = switch (parsed.value) {
        .object => |root| switch (root.get("engines") orelse .null) {
            .array => |array| array,
            else => return malformed(out),
        },
        else => return malformed(out),
    };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    for (engines.items) |item| {
        const engine = switch (item) {
            .object => |object| object,
            else => return malformed(out),
        };
        const name = stringField(engine, "name") orelse return malformed(out);
        const version = stringField(engine, "version") orelse return malformed(out);
        const source = stringField(engine, "source") orelse return malformed(out);
        const pinned = stringField(engine, "sha256") orelse return malformed(out);

        try out.print("vendor-engines: {s} @ {s}\n", .{ name, version });

        // Fetch the pinned archive into memory.
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const result = client.fetch(.{
            .location = .{ .url = source },
            .response_writer = &body.writer,
        }) catch |fetch_error| {
            try out.print("  fetch failed: {t}\n", .{fetch_error});
            try out.flush();
            return 1;
        };
        if (result.status != .ok) {
            try out.print("  fetch returned HTTP {d}\n", .{@intFromEnum(result.status)});
            try out.flush();
            return 1;
        }

        // Verify the digest before a single byte is written to the tree.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body.written(), &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &got, pinned)) {
            try out.print("  DIGEST MISMATCH: pinned {s}, received {s}\n", .{ pinned, got[0..] });
            try out.flush();
            return 1;
        }

        // Unpack the verified archive into a fresh cache directory.
        const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cache_root, name });
        const cwd = io_adapters.cwd();
        cwd.deleteTree(io, dest) catch {};
        try cwd.createDirPath(io, dest);
        var dir = try cwd.openDir(io, dest, .{});
        defer dir.close(io);

        var input: std.Io.Reader = .fixed(body.written());
        var window: [64 * 1024]u8 = undefined;
        var decompress = flate.Decompress.init(&input, .gzip, &window);
        tar.extract(io, dir, &decompress.reader, .{ .strip_components = 1 }) catch |unpack_error| {
            try out.print("  unpack failed: {t}\n", .{unpack_error});
            try out.flush();
            return 1;
        };

        try out.print("  verified {s} and unpacked into {s}/\n", .{ got[0..12], dest });
    }

    try out.print("vendor-engines: {d} engine(s) vendored and verified against the pin\n", .{engines.items.len});
    try out.flush();
    return 0;
}

fn malformed(out: anytype) !u8 {
    try out.print("vendor-engines: {s} is malformed\n", .{manifest_path});
    try out.flush();
    return 3;
}

/// A non-empty string field of a JSON object, or null.
fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

// --- Tests ---

const testing = std.testing;

test "the digest of known bytes is its lowercase hex, as the verify step compares" {
    // A regression guard on the exact hashing the verify path relies on.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
}

test "stringField reads present non-empty strings and rejects the rest" {
    const text =
        \\{"name":"vulkan-headers","empty":"","number":7}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("vulkan-headers", stringField(object, "name").?);
    try testing.expect(stringField(object, "empty") == null);
    try testing.expect(stringField(object, "number") == null);
    try testing.expect(stringField(object, "absent") == null);
}
