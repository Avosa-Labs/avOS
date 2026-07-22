//! Verifies that product naming has not leaked out of the brand resource layer.
//!
//! The product name is a replaceable configuration value. It stays replaceable
//! only while it appears in resources and never in module names, namespaces,
//! service names, wire identifiers, disk formats, environment variables,
//! capability kinds, system paths, log fields, comments, or test semantics.
//! This check distinguishes the locations where naming legitimately lives from
//! the ones where it would become architecture.
//!
//! Exit codes: 0 clean, 1 leak found, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const brand = @import("brand");

/// Locations that own product naming. A match inside one of these is expected.
///
/// Documentation is included because product-facing documentation
/// intentionally discusses the tentative brand; it is prose, not an identifier
/// that other components resolve against.
const brand_owned_prefixes = [_][]const u8{
    "brand/",
    "docs/",
    "README.md",
    "NOTICE",
};

/// Trees that are generated, vendored, or version-control metadata. They are
/// not authored source and are not part of the brand boundary.
const skipped_prefixes = [_][]const u8{
    ".git/",
    ".tools/",
    ".zig-cache/",
    "out/",
    "zig-out/",
};

/// Extensions whose contents declare or consume technical identifiers. A
/// product name inside one of these is a leak unless the file is brand-owned.
const scanned_extensions = [_][]const u8{
    ".zig",
    ".zon",
    ".json",
    ".sh",
    ".ps1",
    ".yml",
    ".yaml",
    ".toml",
    ".wit",
    ".md",
};

const max_scanned_file_bytes = 4 * 1024 * 1024;

const Finding = struct {
    path: []const u8,
    line_number: usize,
    term: []const u8,
    text: []const u8,
};

const Options = struct {
    root: []const u8 = ".",
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

    // The terms are the configured brand's own values. Checking against the
    // active configuration means a rebrand automatically checks the new name
    // without editing this tool.
    const terms = [_][]const u8{ brand.active.name, brand.active.short_name };

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    var root = try io_adapters.cwd().openDir(io, options.root, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (hasAnyPrefix(entry.path, &skipped_prefixes)) continue;
        if (hasAnyPrefix(entry.path, &brand_owned_prefixes)) continue;
        if (!hasScannedExtension(entry.path)) continue;

        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(max_scanned_file_bytes)) catch |read_error| switch (read_error) {
            error.StreamTooLong => continue,
            else => return read_error,
        };
        defer gpa.free(contents);

        const owned_path = try arena.dupe(u8, entry.path);
        try collectFindings(arena, gpa, owned_path, contents, &terms, &findings);
    }

    switch (options.format) {
        .text => try reportText(out, findings.items),
        .json => try reportJson(out, findings.items),
    }
    try out.flush();

    return if (findings.items.len == 0) 0 else 1;
}

fn collectFindings(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    terms: []const []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |text| {
        line_number += 1;
        for (terms) |term| {
            if (term.len == 0) continue;
            if (indexOfIgnoreCase(text, term) == null) continue;
            try findings.append(gpa, .{
                .path = path,
                .line_number = line_number,
                .term = term,
                .text = try arena.dupe(u8, std.mem.trim(u8, text, " \t\r")),
            });
            break;
        }
    }
}

/// Case-insensitive search. Capitalization does not change whether a term has
/// become part of an identifier, so upper, lower, and mixed spellings all count
/// as leaks.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return start;
    }
    return null;
}

fn hasAnyPrefix(path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

fn hasScannedExtension(path: []const u8) bool {
    for (scanned_extensions) |extension| {
        if (std.mem.endsWith(u8, path, extension)) return true;
    }
    return false;
}

fn reportText(out: *std.Io.Writer, findings: []const Finding) !void {
    if (findings.len == 0) {
        try out.writeAll("brand-check: no product naming outside the brand resource layer\n");
        return;
    }
    for (findings) |finding| {
        try out.print("{s}:{d}: brand term '{s}' outside the brand resource layer\n    {s}\n", .{
            finding.path,
            finding.line_number,
            finding.term,
            finding.text,
        });
    }
    try out.print("\nbrand-check: {d} leak(s) found\n", .{findings.len});
}

fn reportJson(out: *std.Io.Writer, findings: []const Finding) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("leak_count");
    try stringify.write(findings.len);
    try stringify.objectField("findings");
    try stringify.beginArray();
    for (findings) |finding| {
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(finding.path);
        try stringify.objectField("line");
        try stringify.write(finding.line_number);
        try stringify.objectField("term");
        try stringify.write(finding.term);
        try stringify.objectField("text");
        try stringify.write(finding.text);
        try stringify.endObject();
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
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            const value = argument["--format=".len..];
            options.format = std.meta.stringToEnum(Options.Format, value) orelse {
                try err.print("brand-check: unknown format '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else {
            try err.print("brand-check: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: brand-check [options]
        \\
        \\Verifies that product naming appears only in the brand resource layer.
        \\
        \\Options:
        \\  --root=<path>      Directory to scan (default: current directory)
        \\  --format=text|json Output format (default: text)
        \\  -h, --help         Show this message
        \\
        \\Exit codes:
        \\  0  no leak found
        \\  1  at least one leak found
        \\  2  usage error
        \\
    );
}

test "case-insensitive search finds every spelling that would reach an identifier" {
    // Fixtures use a token that is deliberately not any configured brand.
    // Reusing a live brand term would make this tool fail its own check
    // whenever that brand were selected.
    try std.testing.expect(indexOfIgnoreCase("const FixturebrandKind = enum", "fixturebrand") != null);
    try std.testing.expect(indexOfIgnoreCase("FIXTUREBRAND_HOME", "Fixturebrand") != null);
    try std.testing.expect(indexOfIgnoreCase("service.fixturebrand.principal", "Fixturebrand") != null);
    try std.testing.expect(indexOfIgnoreCase("a principal service", "Fixturebrand") == null);
}

test "search handles needles longer than the text" {
    try std.testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("ab", "abcdef"));
    try std.testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("", "a"));
}

test "brand-owned locations are exempt and generated trees are skipped" {
    try std.testing.expect(hasAnyPrefix("brand/current/brand.json", &brand_owned_prefixes));
    try std.testing.expect(hasAnyPrefix("docs/public/architecture-overview.md", &brand_owned_prefixes));
    try std.testing.expect(!hasAnyPrefix("core/principal/principal.zig", &brand_owned_prefixes));
    try std.testing.expect(hasAnyPrefix("out/image.img", &skipped_prefixes));
    try std.testing.expect(!hasAnyPrefix("core/task/task.zig", &skipped_prefixes));
}

test "only identifier-bearing file types are scanned" {
    try std.testing.expect(hasScannedExtension("services/principal/main.zig"));
    try std.testing.expect(hasScannedExtension("build.zig.zon"));
    try std.testing.expect(!hasScannedExtension("design/icons/generated/home.svg"));
    try std.testing.expect(!hasScannedExtension("brand/current/logos/mark.png"));
}

test "a leak is reported with its line number" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    const contents =
        \\const std = @import("std");
        \\pub const FixturebrandPrincipal = struct {};
        \\
    ;
    try collectFindings(
        arena_state.allocator(),
        gpa,
        "core/principal/principal.zig",
        contents,
        &.{"Fixturebrand"},
        &findings,
    );

    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(@as(usize, 2), findings.items[0].line_number);
}

test "clean source produces no finding" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    const contents =
        \\pub const PrincipalKind = enum { human, agent, application };
        \\
    ;
    try collectFindings(
        arena_state.allocator(),
        gpa,
        "core/principal/principal.zig",
        contents,
        &.{"Fixturebrand"},
        &findings,
    );
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "one finding per line even when several terms match" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    try collectFindings(
        arena_state.allocator(),
        gpa,
        "services/session/main.zig",
        "// Fixturebrand session host for Fixturebrand endpoints\n",
        &.{ "Fixturebrand", "Fixturebrand" },
        &findings,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}
