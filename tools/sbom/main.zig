//! Emits a software bill of materials for the source tree, deterministically.
//!
//! A bill of materials answers "what is in this build, and did it change" without anyone having to
//! read the whole tree. It lists each top-level component — the sections of the platform — with the
//! number of files it contains, its total size, and a digest over its contents. The digest is what
//! makes the bill useful for supply-chain review: two builds of the same source produce the same bill,
//! and a single changed byte in a component changes that component's digest and nothing else, so a
//! reviewer sees exactly which component moved.
//!
//! Like the image builder, the bill carries nothing that varies between checkouts of identical source:
//! no timestamps, no builder identity, no host paths, no permission bits. Version control metadata,
//! downloaded toolchains, caches, and generated output are excluded, because they differ between
//! checkouts for reasons that have nothing to do with what the build contains.
//!
//! Exit codes: 0 emitted, 1 the tree cannot be read, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const packaging = @import("packaging");

const image = packaging.image;

/// Trees that are not part of what a build contains.
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

/// Largest file the bill will read.
const max_file_bytes: usize = 512 * 1024 * 1024;

/// One file's contribution to the bill.
const FileEntry = struct {
    /// The full path from the tree root.
    path: []const u8,
    /// The digest of the file's contents.
    digest: [image.digest_bytes]u8,
    /// The file's size in bytes.
    size_bytes: usize,

    /// The component a file belongs to: its first path segment. A file at the root belongs to the
    /// "(root)" component so nothing is silently dropped.
    fn component(entry: FileEntry) []const u8 {
        const slash = std.mem.indexOfScalar(u8, entry.path, '/') orelse return "(root)";
        return entry.path[0..slash];
    }
};

/// A component's summary line in the bill.
const Component = struct {
    name: []const u8,
    file_count: usize,
    total_bytes: usize,
    digest: [image.digest_bytes]u8,
};

/// Orders entries by component first, then by path within a component. Sorting by full path alone
/// would not group the root component: a root file like "build.zig" sorts between "agents/…" and
/// "core/…", scattering the root bucket. Ordering by component first makes every component's files
/// contiguous, which is what the fold relies on.
fn lessThanEntryByPath(_: void, a: FileEntry, b: FileEntry) bool {
    const order = std.mem.order(u8, a.component(), b.component());
    if (order != .eq) return order == .lt;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn lessThanComponentByName(_: void, a: Component, b: Component) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Folds sorted file entries into component summaries.
///
/// Entries must be sorted by `lessThanEntryByPath` (component, then path) so the fold is
/// deterministic: a component's digest is taken over each of its files' path and content digest, in
/// path order, so it depends only on what the component contains and not on the order the tree was
/// walked. That ordering makes every component's files — including the root bucket — contiguous.
fn summarize(gpa: std.mem.Allocator, entries: []const FileEntry) !std.ArrayList(Component) {
    var components: std.ArrayList(Component) = .empty;
    errdefer components.deinit(gpa);

    var index: usize = 0;
    while (index < entries.len) {
        const name = entries[index].component();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var file_count: usize = 0;
        var total_bytes: usize = 0;

        while (index < entries.len and std.mem.eql(u8, entries[index].component(), name)) : (index += 1) {
            const entry = entries[index];
            hasher.update(entry.path);
            hasher.update(&.{0});
            hasher.update(&entry.digest);
            file_count += 1;
            total_bytes += entry.size_bytes;
        }

        var digest: [image.digest_bytes]u8 = undefined;
        hasher.final(&digest);
        try components.append(gpa, .{
            .name = name,
            .file_count = file_count,
            .total_bytes = total_bytes,
            .digest = digest,
        });
    }
    return components;
}

const Options = struct {
    root: []const u8 = ".",
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

    var entries: std.ArrayList(FileEntry) = .empty;
    defer entries.deinit(gpa);

    var root = io_adapters.cwd().openDir(io, options.root, .{ .iterate = true }) catch {
        try err.print("sbom: cannot open '{s}'\n", .{options.root});
        try err.flush();
        return 1;
    };
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isSkipped(entry.path)) continue;

        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(max_file_bytes)) catch |read_error| switch (read_error) {
            error.StreamTooLong => {
                try err.print("sbom: '{s}' is larger than the bill will read\n", .{entry.path});
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
        });
    }

    std.mem.sort(FileEntry, entries.items, {}, lessThanEntryByPath);

    var components = try summarize(gpa, entries.items);
    defer components.deinit(gpa);
    std.mem.sort(Component, components.items, {}, lessThanComponentByName);

    switch (options.format) {
        .text => try reportText(out, components.items),
        .json => try reportJson(out, components.items),
    }
    try out.flush();
    return 0;
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: sbom [--root DIR] [--format text|json]
                \\
                \\Emits a software bill of materials for the source tree: each component
                \\with its file count, total size, and a content digest.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len) {
                try err.print("sbom: --root needs a directory\n", .{});
                return error.InvalidArguments;
            }
            options.root = args[index];
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= args.len) {
                try err.print("sbom: --format needs text or json\n", .{});
                return error.InvalidArguments;
            }
            if (std.mem.eql(u8, args[index], "text")) {
                options.format = .text;
            } else if (std.mem.eql(u8, args[index], "json")) {
                options.format = .json;
            } else {
                try err.print("sbom: unknown format '{s}'\n", .{args[index]});
                return error.InvalidArguments;
            }
        } else {
            try err.print("sbom: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn printHex(out: *std.Io.Writer, digest: [image.digest_bytes]u8) !void {
    for (digest) |byte| try out.print("{x:0>2}", .{byte});
}

fn reportText(out: *std.Io.Writer, components: []const Component) !void {
    try out.print("software bill of materials\n", .{});
    for (components) |component| {
        try out.print("  ", .{});
        try printHex(out, component.digest);
        try out.print("  {s}  ({d} file(s), {d} bytes)\n", .{ component.name, component.file_count, component.total_bytes });
    }
}

fn reportJson(out: *std.Io.Writer, components: []const Component) !void {
    try out.print("{{\"components\":[", .{});
    for (components, 0..) |component, index| {
        if (index != 0) try out.print(",", .{});
        try out.print("{{\"name\":\"{s}\",\"files\":{d},\"bytes\":{d},\"digest\":\"", .{
            component.name, component.file_count, component.total_bytes,
        });
        try printHex(out, component.digest);
        try out.print("\"}}", .{});
    }
    try out.print("]}}\n", .{});
}

fn makeEntry(path: []const u8, marker: u8, size: usize) FileEntry {
    return .{ .path = path, .digest = [_]u8{marker} ** image.digest_bytes, .size_bytes = size };
}

test "a file's component is its first path segment" {
    try std.testing.expectEqualStrings("session", makeEntry("session/host/presenter.zig", 1, 10).component());
    try std.testing.expectEqualStrings("(root)", makeEntry("build.zig", 1, 10).component());
}

test "summarize groups files by component and counts them" {
    const gpa = std.testing.allocator;
    var entries = [_]FileEntry{
        makeEntry("a/one.zig", 1, 10),
        makeEntry("a/two.zig", 2, 20),
        makeEntry("b/one.zig", 3, 5),
    };
    std.mem.sort(FileEntry, &entries, {}, lessThanEntryByPath);
    var components = try summarize(gpa, &entries);
    defer components.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), components.items.len);
    try std.testing.expectEqualStrings("a", components.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), components.items[0].file_count);
    try std.testing.expectEqual(@as(usize, 30), components.items[0].total_bytes);
    try std.testing.expectEqualStrings("b", components.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), components.items[1].file_count);
}

test "root files scattered among components fold into a single component" {
    // Root files ("build.zig", "flake.nix") sort between component directories by full path; the
    // component-first ordering must still gather them into one "(root)" component rather than several.
    const gpa = std.testing.allocator;
    var entries = [_]FileEntry{
        makeEntry("agents/a.zig", 1, 10),
        makeEntry("build.zig", 2, 20),
        makeEntry("core/c.zig", 3, 30),
        makeEntry("flake.nix", 4, 40),
    };
    std.mem.sort(FileEntry, &entries, {}, lessThanEntryByPath);
    var components = try summarize(gpa, &entries);
    defer components.deinit(gpa);

    var root_count: usize = 0;
    for (components.items) |component| {
        if (std.mem.eql(u8, component.name, "(root)")) {
            root_count += 1;
            try std.testing.expectEqual(@as(usize, 2), component.file_count);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), root_count);
}

test "a component's digest changes when its content changes, and is stable otherwise" {
    const gpa = std.testing.allocator;

    var base = [_]FileEntry{ makeEntry("a/one.zig", 1, 10), makeEntry("a/two.zig", 2, 20) };
    std.mem.sort(FileEntry, &base, {}, lessThanEntryByPath);
    var first = try summarize(gpa, &base);
    defer first.deinit(gpa);

    // Same input again → same digest.
    var again = try summarize(gpa, &base);
    defer again.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &first.items[0].digest, &again.items[0].digest);

    // One file's content digest changes → the component digest changes.
    var changed = [_]FileEntry{ makeEntry("a/one.zig", 9, 10), makeEntry("a/two.zig", 2, 20) };
    std.mem.sort(FileEntry, &changed, {}, lessThanEntryByPath);
    var moved = try summarize(gpa, &changed);
    defer moved.deinit(gpa);
    try std.testing.expect(!std.mem.eql(u8, &first.items[0].digest, &moved.items[0].digest));
}
