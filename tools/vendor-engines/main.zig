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
//! Downloaded archives are kept in `.engine-archives/<name>.tar.gz` so a later run reuses the
//! bytes instead of re-fetching (llama.cpp alone is ~300MB). The cache holds the archive, never
//! the extracted tree, and the digest is re-verified on every run whether the bytes came from
//! the cache or the network — a corrupt cache entry fails the same check and is dropped, so the
//! cache is only ever a fetch shortcut, never a verification shortcut.
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
const archive_root = ".engine-archives";

// Cached archives can be large (llama.cpp is ~300MB); read them back with a
// generous ceiling rather than the manifest's small one.
const archive_limit: std.Io.Limit = .limited(2 * 1024 * 1024 * 1024);

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

        const cwd = io_adapters.cwd();
        const archive_path = try archivePath(arena, name);

        // Obtain the archive bytes: reuse the cached archive if one is present,
        // otherwise fetch it from the pinned source. Either way the bytes pass
        // through the identical digest check below — the cache is a fetch
        // shortcut, never a verification shortcut.
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        var bytes: []const u8 = undefined;
        const from_cache = cache: {
            if (cwd.readFileAlloc(io, archive_path, gpa, archive_limit)) |cached| {
                try out.print("  using cached archive {s}\n", .{archive_path});
                bytes = cached;
                break :cache true;
            } else |_| {
                // Not cached (or unreadable): fetch the pinned archive into memory.
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
                bytes = body.written();
                break :cache false;
            }
        };
        defer if (from_cache) gpa.free(bytes);

        // Verify the digest before a single byte is written to the tree. This
        // runs for the cached and the freshly fetched case alike.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &got, pinned)) {
            if (from_cache) {
                // The cached archive is corrupt; drop it and make the user re-run.
                cwd.deleteTree(io, archive_path) catch {};
                try out.print(
                    "  cached archive corrupt: pinned {s}, got {s} — removed {s}, re-run vendor-engines\n",
                    .{ pinned, got[0..], archive_path },
                );
            } else {
                try out.print("  DIGEST MISMATCH: pinned {s}, received {s}\n", .{ pinned, got[0..] });
            }
            try out.flush();
            return 1;
        }

        // A fresh fetch verified: persist it so the next run reuses the bytes.
        // Best-effort — a write failure only forfeits the shortcut next time.
        if (!from_cache) {
            cwd.createDirPath(io, archive_root) catch {};
            io_adapters.writeFile(cwd, io, archive_path, bytes) catch {};
        }

        // Unpack the verified archive into a fresh cache directory.
        const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cache_root, name });
        cwd.deleteTree(io, dest) catch {};
        try cwd.createDirPath(io, dest);
        var dir = try cwd.openDir(io, dest, .{});
        defer dir.close(io);

        var input: std.Io.Reader = .fixed(bytes);
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

/// The cached-archive path for an engine, under `archive_root`.
fn archivePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ archive_root, name });
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

test "archivePath places each engine's archive under the archive root" {
    const path = try archivePath(testing.allocator, "vulkan-headers");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(".engine-archives/vulkan-headers.tar.gz", path);
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
