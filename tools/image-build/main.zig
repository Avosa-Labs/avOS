//! Builds a system image from a directory, deterministically.
//!
//! Two runs over the same files produce the same digest, on any host, in any
//! order, at any time. That is not an aspiration the tool tries for; it is what
//! the format makes unavoidable by carrying no timestamp, no builder identity,
//! no host path, and a canonical entry order.
//!
//! What is deliberately not read: modification times, ownership, and every
//! permission bit except the executable one. Each varies between checkouts of
//! identical source, so including any of them would mean two people building the
//! same commit get different images and neither could tell why.
//!
//! Exit codes: 0 built, 1 the directory cannot be made into an image, 2 usage
//! error.

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

/// Largest file an image may carry.
const max_file_bytes: usize = 512 * 1024 * 1024;

const Options = struct {
    root: []const u8 = ".",
    device_class: []const u8 = "reference",
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    security_generation: u32 = 0,
    format: Format = .text,

    const Format = enum { text, json };
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [64 * 1024]u8 = undefined;
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

    var entries: std.ArrayList(image.Entry) = .empty;
    defer entries.deinit(gpa);

    var root = io_adapters.cwd().openDir(io, options.root, .{ .iterate = true }) catch {
        try err.print("image-build: cannot open '{s}'\n", .{options.root});
        try err.flush();
        return 1;
    };
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isSkipped(entry.path)) continue;

        const contents = root.readFileAlloc(
            io,
            entry.path,
            gpa,
            .limited(max_file_bytes),
        ) catch |read_error| switch (read_error) {
            error.StreamTooLong => {
                try err.print("image-build: '{s}' is larger than an image may carry\n", .{
                    entry.path,
                });
                try err.flush();
                return 1;
            },
            else => return read_error,
        };
        defer gpa.free(contents);

        try entries.append(gpa, .{
            .path = try arena.dupe(u8, entry.path),
            .digest = image.digestOf(contents),
            .size_bytes = contents.len,
            // Nothing in this tree is executable by virtue of being in an
            // image. A build that produced binaries would set this from the
            // mode bit; reading it from the checkout would make the image
            // depend on how the source was cloned.
            .executable = false,
        });
    }

    // Sorted by the format's own rule rather than by one that happens to agree,
    // so the order the builder writes is the order the validator checks.
    std.mem.sort(image.Entry, entries.items, {}, image.lessThanByPath);

    const manifest: image.Manifest = .{
        .identity = .{
            .device_class = options.device_class,
            .major = options.major,
            .minor = options.minor,
            .patch = options.patch,
            .security_generation = options.security_generation,
        },
        .entries = entries.items,
    };

    const digest = manifest.digest() catch |failure| {
        try err.print("image-build: {s}\n", .{describe(failure)});
        try err.flush();
        return 1;
    };

    switch (options.format) {
        .text => try reportText(out, manifest, digest),
        .json => try reportJson(out, manifest, digest),
    }
    try out.flush();
    return 0;
}

fn describe(failure: image.Error) []const u8 {
    return switch (failure) {
        error.DuplicatePath => "two files claim the same path",
        error.PathNotAllowed => "a path is absolute or climbs out of the image root",
        error.PathTooLong => "a path is longer than an entry may carry",
        error.TooManyEntries => "more files than an image may contain",
        error.OrderNotCanonical => "entries are not in the order the format requires",
    };
}

fn reportText(
    out: *std.Io.Writer,
    manifest: image.Manifest,
    digest: [image.digest_bytes]u8,
) !void {
    try out.print("image {d}.{d}.{d} for {s}\n", .{
        manifest.identity.major,
        manifest.identity.minor,
        manifest.identity.patch,
        manifest.identity.device_class,
    });
    try out.print("security generation {d}\n", .{manifest.identity.security_generation});
    try out.print("{d} file(s), {d} byte(s)\n", .{
        manifest.entries.len,
        manifest.totalBytes(),
    });
    try out.print("digest {x}\n", .{digest});
}

fn reportJson(
    out: *std.Io.Writer,
    manifest: image.Manifest,
    digest: [image.digest_bytes]u8,
) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("device_class");
    try stringify.write(manifest.identity.device_class);
    try stringify.objectField("version");
    var version_buffer: [48]u8 = undefined;
    try stringify.write(try std.fmt.bufPrint(&version_buffer, "{d}.{d}.{d}", .{
        manifest.identity.major,
        manifest.identity.minor,
        manifest.identity.patch,
    }));
    try stringify.objectField("security_generation");
    try stringify.write(manifest.identity.security_generation);
    try stringify.objectField("entries");
    try stringify.write(manifest.entries.len);
    try stringify.objectField("total_bytes");
    try stringify.write(manifest.totalBytes());
    try stringify.objectField("digest");
    var digest_buffer: [image.digest_bytes * 2]u8 = undefined;
    try stringify.write(try std.fmt.bufPrint(&digest_buffer, "{x}", .{digest}));
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
        } else if (std.mem.startsWith(u8, argument, "--device-class=")) {
            options.device_class = argument["--device-class=".len..];
        } else if (std.mem.startsWith(u8, argument, "--version=")) {
            parseVersion(argument["--version=".len..], &options) catch {
                try err.writeAll("image-build: version must be major.minor.patch\n");
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, argument, "--security-generation=")) {
            options.security_generation = std.fmt.parseInt(
                u32,
                argument["--security-generation=".len..],
                10,
            ) catch {
                try err.writeAll("image-build: security generation must be a number\n");
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            const value = argument["--format=".len..];
            options.format = std.meta.stringToEnum(Options.Format, value) orelse {
                try err.print("image-build: unknown format '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else {
            try err.print("image-build: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn parseVersion(text: []const u8, options: *Options) !void {
    var parts = std.mem.splitScalar(u8, text, '.');
    options.major = try std.fmt.parseInt(u32, parts.next() orelse return error.Malformed, 10);
    options.minor = try std.fmt.parseInt(u32, parts.next() orelse return error.Malformed, 10);
    options.patch = try std.fmt.parseInt(u32, parts.next() orelse return error.Malformed, 10);
    if (parts.next() != null) return error.Malformed;
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: image-build [options]
        \\
        \\Reduces a directory to a system image digest. Two runs over the same
        \\files produce the same digest on any host at any time: the format
        \\carries no timestamp, no builder identity, and no host path, and its
        \\entry order is canonical rather than whatever the filesystem returned.
        \\
        \\Options:
        \\  --root=<path>                 Directory to build (default: .)
        \\  --device-class=<name>         Hardware this image is for
        \\  --version=<major.minor.patch> Version the image declares
        \\  --security-generation=<n>     Raised when a fix must not be undone
        \\  --format=text|json            Output format (default: text)
        \\  -h, --help                    Show this message
        \\
        \\Exit codes:
        \\  0  built
        \\  1  the directory cannot be made into an image
        \\  2  usage error
        \\
    );
}

test "a version is parsed only in the form the format uses" {
    var options: Options = .{};
    try parseVersion("1.2.3", &options);
    try std.testing.expectEqual(@as(u32, 1), options.major);
    try std.testing.expectEqual(@as(u32, 2), options.minor);
    try std.testing.expectEqual(@as(u32, 3), options.patch);

    // A version with a missing or extra component is refused rather than
    // guessed at: guessing would put a different number in a signed image than
    // the one someone typed.
    try std.testing.expect(std.meta.isError(parseVersion("1.2", &options)));
    try std.testing.expect(std.meta.isError(parseVersion("1.2.3.4", &options)));
    try std.testing.expect(std.meta.isError(parseVersion("", &options)));
    try std.testing.expect(std.meta.isError(parseVersion("1.2.x", &options)));
}

test "every reason an image cannot be built has a description" {
    const failures = [_]image.Error{
        error.DuplicatePath,
        error.PathNotAllowed,
        error.PathTooLong,
        error.TooManyEntries,
        error.OrderNotCanonical,
    };
    for (failures) |failure| {
        try std.testing.expect(describe(failure).len > 0);
    }
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
