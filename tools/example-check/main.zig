//! Verifies that the SDK example registry and the examples on disk are the same set:
//! every registered example is real, and every real example is registered.
//!
//! The registry's whole promise is that a name a developer follows from the docs resolves
//! to an example that actually exists and builds — a closed set with no dead links. That
//! promise is only kept if something checks it, because nothing in the registry data
//! itself forces the path it names to exist, or forces an example added on disk to be
//! listed. This gate is that check. A registered example must be a directory holding a
//! manifest and at least one source file; an example directory holding a manifest must be
//! registered. Either half broken — a name pointing at a missing directory, an example
//! shipped but unlisted — is a build error caught here, so the registry cannot rot into
//! the broken links it exists to prevent.
//!
//! Exit codes: 0 clean, 1 the registry and disk disagree.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// The registry data, read as text so this gate checks the exact file the SDK resolves
/// from. A registered example is a `.path = "examples/..."` entry.
const registry_path = "sdk/examples/registry.zon";

/// Where examples live on disk. Each real example is a subdirectory here.
const examples_root = "examples";

/// A file that marks a directory as a real, shippable example rather than a note.
const manifest_name = "manifest.zon";

const max_file_bytes: usize = 1 * 1024 * 1024;

const Finding = struct {
    kind: enum {
        registered_but_missing, // a registry entry with no real example behind it
        real_but_unregistered, // an example on disk not in the registry
    },
    subject: []const u8,
    detail: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buffer);
    const out = &out_file.interface;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    const cwd = io_adapters.cwd();

    // The registered paths, extracted from the registry file.
    const registry_text = try cwd.readFileAlloc(io, registry_path, gpa, .limited(max_file_bytes));
    defer gpa.free(registry_text);

    var registered: std.ArrayList([]const u8) = .empty;
    defer registered.deinit(gpa);
    try collectRegisteredPaths(gpa, registry_text, &registered);

    // Every registered example must be a real directory with a manifest and a source.
    for (registered.items) |path| {
        const has_manifest = fileExists(io, cwd, path, manifest_name);
        const has_source = try dirHasSource(io, cwd, path);
        if (!has_manifest or !has_source) {
            try findings.append(gpa, .{
                .kind = .registered_but_missing,
                .subject = path,
                .detail = if (!has_manifest) "no manifest.zon" else "no .zig source",
            });
        }
    }

    // Every example directory on disk that carries a manifest must be registered.
    var root = try cwd.openDir(io, examples_root, .{ .iterate = true });
    defer root.close(io);
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ examples_root, entry.name });
        if (!fileExists(io, cwd, path, manifest_name)) continue; // a note, not an example
        if (!isRegistered(registered.items, path)) {
            try findings.append(gpa, .{
                .kind = .real_but_unregistered,
                .subject = path,
                .detail = "has a manifest but is not in the registry",
            });
        }
    }

    if (findings.items.len == 0) {
        try out.writeAll("example-check: the registry and the examples on disk are the same set\n");
        try out.flush();
        return 0;
    }
    for (findings.items) |finding| {
        switch (finding.kind) {
            .registered_but_missing => try out.print(
                "{s}: registered but not a real example ({s}); build it or remove it from {s}\n",
                .{ finding.subject, finding.detail, registry_path },
            ),
            .real_but_unregistered => try out.print(
                "{s}: {s}; add it to {s} or remove its manifest\n",
                .{ finding.subject, finding.detail, registry_path },
            ),
        }
    }
    try out.print("example-check: {d} registry/disk disagreement(s)\n", .{findings.items.len});
    try out.flush();
    return 1;
}

/// Extracts every `.path = "..."` value from the registry text into `out`. The values
/// are slices into `text`, which must outlive `out`.
fn collectRegisteredPaths(
    gpa: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const marker = ".path = \"";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, marker)) |at| {
        const value_start = at + marker.len;
        const end = std.mem.indexOfScalarPos(u8, text, value_start, '"') orelse break;
        try out.append(gpa, text[value_start..end]);
        search = end + 1;
    }
}

fn isRegistered(registered: []const []const u8, path: []const u8) bool {
    for (registered) |entry| {
        if (std.mem.eql(u8, entry, path)) return true;
    }
    return false;
}

fn fileExists(
    io: anytype,
    cwd: anytype,
    dir_path: []const u8,
    file_name: []const u8,
) bool {
    var dir = cwd.openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    const file = dir.openFile(io, file_name, .{}) catch return false;
    file.close(io);
    return true;
}

/// Whether a directory holds at least one `.zig` source file — the example's real code.
fn dirHasSource(
    io: anytype,
    cwd: anytype,
    dir_path: []const u8,
) !bool {
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) return true;
    }
    return false;
}

const testing = std.testing;

test "every registered path is extracted from the registry text" {
    const text =
        \\.{
        \\    .{ .name = "hello-agent", .path = "examples/hello-agent" },
        \\    .{ .name = "todo-app", .path = "examples/todo-app" },
        \\}
    ;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(testing.allocator);
    try collectRegisteredPaths(testing.allocator, text, &paths);

    try testing.expectEqual(@as(usize, 2), paths.items.len);
    try testing.expectEqualStrings("examples/hello-agent", paths.items[0]);
    try testing.expectEqualStrings("examples/todo-app", paths.items[1]);
}

test "membership is exact and a path absent from the registry is unregistered" {
    const registered = [_][]const u8{ "examples/hello-agent", "examples/todo-app" };
    try testing.expect(isRegistered(&registered, "examples/todo-app"));
    try testing.expect(!isRegistered(&registered, "examples/camera-capture"));
    try testing.expect(!isRegistered(&registered, ""));
}
