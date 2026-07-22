//! Checks that building the same source twice produces the same image.
//!
//! Reproducibility is the property that makes a signature worth anything to
//! someone who did not build the artifact. Without it, a signature says a
//! particular machine produced these bytes; with it, it says these bytes follow
//! from this source, and anyone can check that claim for themselves.
//!
//! This runs the build twice and compares the digests. Running it twice in the
//! same place catches what varies within a host — iteration order, uninitialized
//! padding, anything reading a clock. It does not catch what varies between
//! hosts, which is why the gate set runs on more than one.
//!
//! Exit codes: 0 the two builds agree, 1 they do not, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const packaging = @import("packaging");

const image = packaging.image;

/// Trees that are not part of what a build produces.
///
/// Version-control metadata, downloaded toolchains, and caches all differ
/// between two checkouts of identical source. Including them would report the
/// build as unreproducible for reasons that have nothing to do with the build.
const skipped_prefixes = [_][]const u8{
    ".git/",
    ".tools/",
    ".zig-cache/",
    "out/",
    "zig-out/",
};

fn isSkipped(path: []const u8) bool {
    for (skipped_prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

/// Largest file the walk will read.
const max_file_bytes: usize = 512 * 1024 * 1024;

const Options = struct {
    root: []const u8 = ".",
    /// How many times to build. Two proves the property; more is for chasing a
    /// difference that only appears sometimes.
    rounds: usize = 2,
    format: Format = .text,

    const Format = enum { text, json };
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buffer);
    const out = &out_file.interface;

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const options = parseArguments(args, out, err) catch |parse_error| switch (parse_error) {
        error.HelpRequested => {
            try out.flush();
            return 0;
        },
        error.InvalidArguments => {
            try err.flush();
            return 2;
        },
        else => return parse_error,
    };

    var digests: std.ArrayList([image.digest_bytes]u8) = .empty;
    defer digests.deinit(gpa);

    for (0..options.rounds) |_| {
        const digest = buildOnce(io, gpa, arena, options.root) catch |failure| {
            try err.print("source-repro: {s}\n", .{@errorName(failure)});
            try err.flush();
            return 1;
        };
        try digests.append(gpa, digest);
    }

    const agree = allEqual(digests.items);
    switch (options.format) {
        .text => try reportText(out, digests.items, agree),
        .json => try reportJson(out, digests.items, agree),
    }
    try out.flush();
    return if (agree) 0 else 1;
}

/// Reduces the tree to a digest, exactly as the image builder does.
///
/// Deliberately re-walks rather than caching the first result: a comparison
/// against a remembered value would prove the memory works, not the build.
fn buildOnce(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
) ![image.digest_bytes]u8 {
    var entries: std.ArrayList(image.Entry) = .empty;
    defer entries.deinit(gpa);

    var root = try io_adapters.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isSkipped(entry.path)) continue;
        const contents = try root.readFileAlloc(io, entry.path, gpa, .limited(max_file_bytes));
        defer gpa.free(contents);

        try entries.append(gpa, .{
            .path = try arena.dupe(u8, entry.path),
            .digest = image.digestOf(contents),
            .size_bytes = contents.len,
            .executable = false,
        });
    }

    std.mem.sort(image.Entry, entries.items, {}, image.lessThanByPath);

    const manifest: image.Manifest = .{
        .identity = .{
            .device_class = "reference",
            .major = 0,
            .minor = 0,
            .patch = 0,
            .security_generation = 0,
        },
        .entries = entries.items,
    };
    return manifest.digest();
}

fn allEqual(digests: []const [image.digest_bytes]u8) bool {
    if (digests.len < 2) return false;
    for (digests[1..]) |digest| {
        if (!std.mem.eql(u8, &digests[0], &digest)) return false;
    }
    return true;
}

fn reportText(
    out: *std.Io.Writer,
    digests: []const [image.digest_bytes]u8,
    agree: bool,
) !void {
    for (digests, 1..) |digest, round| {
        try out.print("  build {d}  {x}\n", .{ round, digest });
    }
    if (agree) {
        try out.print(
            "\nsource-repro: {d} builds of this source produced the same image\n",
            .{digests.len},
        );
    } else {
        try out.writeAll(
            \\
            \\source-repro: builds of the same source produced different images
            \\
            \\Something in the build depends on more than the source: a clock, an
            \\environment variable, an absolute path, an iteration order, or
            \\uninitialized memory that reached an artifact.
            \\
        );
    }
}

fn reportJson(
    out: *std.Io.Writer,
    digests: []const [image.digest_bytes]u8,
    agree: bool,
) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("reproducible");
    try stringify.write(agree);
    try stringify.objectField("digests");
    try stringify.beginArray();
    for (digests) |digest| {
        var buffer: [image.digest_bytes * 2]u8 = undefined;
        try stringify.write(try std.fmt.bufPrint(&buffer, "{x}", .{digest}));
    }
    try stringify.endArray();
    try stringify.endObject();
    try out.writeByte('\n');
}

fn parseArguments(
    args: []const [:0]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            try writeUsage(out);
            return error.HelpRequested;
        } else if (std.mem.startsWith(u8, argument, "--root=")) {
            options.root = argument["--root=".len..];
        } else if (std.mem.startsWith(u8, argument, "--rounds=")) {
            options.rounds = std.fmt.parseInt(usize, argument["--rounds=".len..], 10) catch {
                try err.writeAll("source-repro: rounds must be a number\n");
                return error.InvalidArguments;
            };
            if (options.rounds < 2) {
                // One build cannot disagree with anything, and reporting it as
                // reproducible would be reporting that nothing was checked.
                try err.writeAll("source-repro: at least two rounds are needed\n");
                return error.InvalidArguments;
            }
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            const value = argument["--format=".len..];
            options.format = std.meta.stringToEnum(Options.Format, value) orelse {
                try err.print("source-repro: unknown format '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else {
            try err.print("source-repro: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: source-repro [options]
        \\
        \\Builds the same source more than once and compares the resulting image
        \\digests. Reproducibility is what lets a signature say these bytes
        \\follow from this source, rather than a particular machine produced
        \\these bytes.
        \\
        \\Options:
        \\  --root=<path>       Directory to build (default: .)
        \\  --rounds=<n>        How many builds to compare (minimum 2)
        \\  --format=text|json  Output format (default: text)
        \\  -h, --help          Show this message
        \\
        \\Exit codes:
        \\  0  every build produced the same image
        \\  1  they did not
        \\  2  usage error
        \\
    );
}

test "identical digests agree" {
    const digest: [image.digest_bytes]u8 = @splat(7);
    try std.testing.expect(allEqual(&.{ digest, digest, digest }));
}

test "one differing digest is a disagreement" {
    const digest: [image.digest_bytes]u8 = @splat(7);
    var other: [image.digest_bytes]u8 = digest;
    other[image.digest_bytes - 1] ^= 0x01;

    // The last byte, because a comparison that stopped early would miss it.
    try std.testing.expect(!allEqual(&.{ digest, digest, other }));
    try std.testing.expect(!allEqual(&.{ other, digest }));
}

test "a single build is never reported as reproducible" {
    const digest: [image.digest_bytes]u8 = @splat(7);
    // One build cannot disagree with anything. Calling that reproducible would
    // report that nothing was checked as though something had been.
    try std.testing.expect(!allEqual(&.{digest}));
    try std.testing.expect(!allEqual(&.{}));
}

test "what a build did not produce is left out" {
    // Two checkouts of identical source differ in all of these. Including any
    // would report the build as unreproducible for reasons that are not the
    // build.
    try std.testing.expect(isSkipped(".git/config"));
    try std.testing.expect(isSkipped(".zig-cache/o/abc/thing"));
    try std.testing.expect(isSkipped(".tools/zig-0.16.0/zig"));
    try std.testing.expect(isSkipped("zig-out/bin/tool"));
    try std.testing.expect(isSkipped("out/image"));

    // Authored source is not skipped, including files whose names begin the
    // same way.
    try std.testing.expect(!isSkipped("core/time/time.zig"));
    try std.testing.expect(!isSkipped(".gitignore"));
    try std.testing.expect(!isSkipped("outside/thing.zig"));
}
