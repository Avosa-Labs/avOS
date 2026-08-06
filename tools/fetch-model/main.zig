//! Provisions the pinned on-device model: fetch, verify against the pin, place in the local cache.
//!
//! `model.lock.json` records the default assistant model's upstream file and its SHA-256. This step
//! fetches that file from the pinned source, hashes what it received, and refuses to write it unless
//! the digest is exactly the one recorded — so a substituted or corrupted download never reaches the
//! device. A verified file is placed at `.models/<file>`, where the running OS discovers it
//! automatically. Nothing is committed; the model is rebuilt from the pin on any machine.
//!
//! A model already present with the right digest is left untouched, so re-running is cheap and offline.
//! It is opt-in — `zig build fetch-model` — and not part of the gate set, so ordinary builds and CI stay
//! offline. The digest is the trust boundary: fetching is only ever allowed to place bytes that match
//! the committed pin.
//!
//! Exit codes: 0 every model present and verified, 1 a digest mismatch or fetch failure, 3 the manifest
//! is missing or malformed.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

const manifest_path = "model.lock.json";
const cache_root = ".models";

// A quantised model is hundreds of megabytes; read and buffer it with a generous ceiling.
const model_limit: std.Io.Limit = .limited(4 * 1024 * 1024 * 1024);

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buf);
    const out = &out_file.interface;

    const text = io_adapters.cwd().readFileAlloc(io, manifest_path, gpa, .limited(4 * 1024 * 1024)) catch {
        try out.print("fetch-model: {s} missing\n", .{manifest_path});
        try out.flush();
        return 3;
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch {
        try out.print("fetch-model: {s} is not valid JSON\n", .{manifest_path});
        try out.flush();
        return 3;
    };
    const models = switch (parsed.value) {
        .object => |root| switch (root.get("models") orelse .null) {
            .array => |array| array,
            else => return malformed(out),
        },
        else => return malformed(out),
    };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const cwd = io_adapters.cwd();

    for (models.items) |item| {
        const model = switch (item) {
            .object => |object| object,
            else => return malformed(out),
        };
        const name = stringField(model, "name") orelse return malformed(out);
        const file = stringField(model, "file") orelse return malformed(out);
        const source = stringField(model, "source") orelse return malformed(out);
        const pinned = stringField(model, "sha256") orelse return malformed(out);

        const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cache_root, file });
        try out.print("fetch-model: {s} ({s})\n", .{ name, file });

        // Already provisioned with the right digest: nothing to do. A mismatched or absent file is
        // (re)fetched below.
        if (cwd.readFileAlloc(io, dest, gpa, model_limit)) |present| {
            defer gpa.free(present);
            if (digestMatches(present, pinned)) {
                try out.print("  already present and verified\n", .{});
                continue;
            }
        } else |_| {}

        // Fetch the pinned file into memory, following the source's redirects to its CDN.
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const result = client.fetch(.{ .location = .{ .url = source }, .response_writer = &body.writer }) catch |fetch_error| {
            try out.print("  fetch failed: {t}\n", .{fetch_error});
            try out.flush();
            return 1;
        };
        if (result.status != .ok) {
            try out.print("  fetch returned HTTP {d}\n", .{@intFromEnum(result.status)});
            try out.flush();
            return 1;
        }
        const bytes = body.written();

        // Verify the digest before a single byte is written to the tree.
        if (!digestMatches(bytes, pinned)) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try out.print("  DIGEST MISMATCH: pinned {s}, received {s}\n", .{ pinned, std.fmt.bytesToHex(digest, .lower)[0..] });
            try out.flush();
            return 1;
        }

        cwd.createDirPath(io, cache_root) catch {};
        io_adapters.writeFile(cwd, io, dest, bytes) catch |write_error| {
            try out.print("  could not write {s}: {t}\n", .{ dest, write_error });
            try out.flush();
            return 1;
        };
        try out.print("  verified and placed at {s} ({d} MB)\n", .{ dest, bytes.len / (1024 * 1024) });
    }

    try out.print("fetch-model: {d} model(s) provisioned and verified against the pin\n", .{models.items.len});
    try out.flush();
    return 0;
}

fn malformed(out: anytype) !u8 {
    try out.print("fetch-model: {s} is malformed\n", .{manifest_path});
    try out.flush();
    return 3;
}

/// Whether `bytes` hash to the pinned lowercase-hex SHA-256.
fn digestMatches(bytes: []const u8, pinned: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &got, pinned);
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

test "digestMatches accepts the pinned hash of known bytes and rejects a wrong pin" {
    // "abc" hashes to this SHA-256 — the exact comparison the verify path relies on.
    const abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try testing.expect(digestMatches("abc", abc));
    try testing.expect(!digestMatches("abc", "00" ** 32));
}

test "stringField reads present non-empty strings and rejects the rest" {
    const text =
        \\{"name":"assistant","empty":"","number":7}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("assistant", stringField(object, "name").?);
    try testing.expect(stringField(object, "empty") == null);
    try testing.expect(stringField(object, "number") == null);
    try testing.expect(stringField(object, "absent") == null);
}
