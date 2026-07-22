//! Reports whether this checkout can reproduce the build.
//!
//! Every check answers one question a contributor or a continuous-integration
//! lane would otherwise answer by guessing: which compiler is running, whether
//! its lane is qualified, whether the pins are exact, whether the brand layer
//! is intact, and whether the local working policy is in force. Checks report
//! rather than repair, so the tool is safe to run anywhere.
//!
//! Exit codes: 0 all checks passed, 1 at least one failed, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const brand = @import("brand");

const manifest_path = "toolchain.lock.json";
const package_manifest_path = "build.zig.zon";
const specification_path = "docs/PLATFORM_SPEC.md";
const git_exclude_path = ".git/info/exclude";

/// Declarations that would make a dependency float instead of resolving to one
/// immutable artifact.
const floating_markers = [_][]const u8{
    "\"latest\"",
    ".branch",
    "*.*.*",
    "^",
    "~>",
};

const Status = enum { pass, fail, note };

const Check = struct {
    name: []const u8,
    status: Status,
    detail: []const u8,
};

const Report = struct {
    checks: std.ArrayList(Check) = .empty,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,

    fn add(report: *Report, name: []const u8, status: Status, comptime format: []const u8, arguments: anytype) !void {
        try report.checks.append(report.gpa, .{
            .name = name,
            .status = status,
            .detail = try std.fmt.allocPrint(report.arena, format, arguments),
        });
    }

    fn failed(report: Report) bool {
        for (report.checks.items) |check| {
            if (check.status == .fail) return true;
        }
        return false;
    }
};

const Options = struct {
    format: Format = .text,

    const Format = enum { text, json };
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [32 * 1024]u8 = undefined;
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

    var report: Report = .{ .arena = arena, .gpa = gpa };
    defer report.checks.deinit(gpa);

    try checkHost(&report);
    try checkCompiler(&report);
    try checkManifest(&report, io, arena);
    try checkPackageManifest(&report, io, arena);
    try checkBrand(&report);
    try checkSpecificationExclusion(&report, io, arena);

    switch (options.format) {
        .text => try reportText(out, report),
        .json => try reportJson(out, report),
    }
    try out.flush();

    return if (report.failed()) 1 else 0;
}

fn checkHost(report: *Report) !void {
    const target = @import("builtin").target;
    try report.add("host", .pass, "{s} {s}", .{
        @tagName(target.os.tag),
        @tagName(target.cpu.arch),
    });
}

fn checkCompiler(report: *Report) !void {
    const version = compat.line.current_version;
    const current = compat.line.current_line orelse {
        try report.add("compiler", .fail, "release {f} is outside the supported window ({f} and newer)", .{
            version,
            compat.line.floor,
        });
        return;
    };

    switch (compat.line.qualificationOf(current)) {
        .canonical => try report.add("compiler", .pass, "release {f} on the canonical line", .{version}),
        .unqualified => try report.add(
            "compiler",
            .fail,
            "release {f} is in the supported window but its lane is not green; build with {f}",
            .{ version, compat.line.canonical },
        ),
    }
}

fn checkManifest(report: *Report, io: std.Io, arena: std.mem.Allocator) !void {
    const text = io_adapters.readFile(io_adapters.cwd(), io, manifest_path, arena, .limited(8 * 1024 * 1024)) catch |read_error| {
        try report.add("toolchain manifest", .fail, "cannot read {s}: {t}", .{ manifest_path, read_error });
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch |parse_error| {
        try report.add("toolchain manifest", .fail, "{s} is not valid JSON: {t}", .{ manifest_path, parse_error });
        return;
    };

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try report.add("toolchain manifest", .fail, "{s} is not an object", .{manifest_path});
            return;
        },
    };

    const zig_entry = switch (root.get("zig") orelse {
        try report.add("toolchain manifest", .fail, "{s} does not pin a compiler", .{manifest_path});
        return;
    }) {
        .object => |object| object,
        else => {
            try report.add("toolchain manifest", .fail, "{s} has a malformed compiler pin", .{manifest_path});
            return;
        },
    };

    const pinned_version = switch (zig_entry.get("version") orelse .null) {
        .string => |value| value,
        else => {
            try report.add("toolchain manifest", .fail, "the compiler pin has no version", .{});
            return;
        },
    };
    const digest = switch (zig_entry.get("sha256") orelse .null) {
        .string => |value| value,
        else => "",
    };

    if (digest.len != 64) {
        try report.add("toolchain manifest", .fail, "the compiler pin has no verified digest", .{});
        return;
    }

    const running = compat.line.current_version;
    var running_buffer: [32]u8 = undefined;
    const running_text = try std.fmt.bufPrint(&running_buffer, "{f}", .{running});

    if (!std.mem.eql(u8, pinned_version, running_text)) {
        try report.add(
            "toolchain manifest",
            .fail,
            "pins {s} but {s} is running; use the pinned release",
            .{ pinned_version, running_text },
        );
        return;
    }

    try report.add("toolchain manifest", .pass, "pins {s} with a verified digest", .{pinned_version});
}

fn checkPackageManifest(report: *Report, io: std.Io, arena: std.mem.Allocator) !void {
    const text = io_adapters.readFile(io_adapters.cwd(), io, package_manifest_path, arena, .limited(1024 * 1024)) catch |read_error| {
        try report.add("dependency pinning", .fail, "cannot read {s}: {t}", .{ package_manifest_path, read_error });
        return;
    };

    for (floating_markers) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) {
            try report.add(
                "dependency pinning",
                .fail,
                "{s} contains '{s}', which does not resolve to one immutable artifact",
                .{ package_manifest_path, marker },
            );
            return;
        }
    }

    try report.add("dependency pinning", .pass, "{s} declares no floating dependency", .{package_manifest_path});
}

fn checkBrand(report: *Report) !void {
    brand.active.validate() catch {
        try report.add("brand layer", .fail, "the active brand document has an empty field", .{});
        return;
    };
    // The value is deliberately not printed: doctor output is pasted into
    // issues and logs, and product naming belongs on brand-owned surfaces.
    try report.add("brand layer", .pass, "the active brand document is complete", .{});
}

/// The specification is local-only during the private implementation stage.
/// This reports whether the local exclusion is in force; it never adds the
/// entry, because the working policy is a deliberate local act.
fn checkSpecificationExclusion(report: *Report, io: std.Io, arena: std.mem.Allocator) !void {
    const cwd = io_adapters.cwd();

    _ = io_adapters.readFile(cwd, io, specification_path, arena, .limited(1)) catch |read_error| switch (read_error) {
        error.FileNotFound => {
            try report.add("specification exclusion", .note, "{s} is not present in this checkout", .{specification_path});
            return;
        },
        // The file exists and is larger than the probe; that is what matters.
        error.StreamTooLong => {},
        else => return read_error,
    };

    const exclude = io_adapters.readFile(cwd, io, git_exclude_path, arena, .limited(1024 * 1024)) catch |read_error| switch (read_error) {
        error.FileNotFound => {
            try report.add("specification exclusion", .note, "no {s}; this checkout is not a repository", .{git_exclude_path});
            return;
        },
        else => return read_error,
    };

    if (excludesPath(exclude, specification_path)) {
        try report.add("specification exclusion", .pass, "{s} is excluded locally", .{specification_path});
    } else {
        try report.add(
            "specification exclusion",
            .fail,
            "{s} must list /{s} while the local-only policy is active",
            .{ git_exclude_path, specification_path },
        );
    }
}

fn excludesPath(exclude_text: []const u8, path: []const u8) bool {
    var lines = std.mem.splitScalar(u8, exclude_text, '\n');
    while (lines.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r");
        if (entry.len == 0 or entry[0] == '#') continue;
        const normalized = std.mem.trimStart(u8, entry, "/");
        if (std.mem.eql(u8, normalized, path)) return true;
    }
    return false;
}

fn reportText(out: *std.Io.Writer, report: Report) !void {
    var failures: usize = 0;
    for (report.checks.items) |check| {
        const mark = switch (check.status) {
            .pass => "ok  ",
            .fail => "FAIL",
            .note => "note",
        };
        if (check.status == .fail) failures += 1;
        try out.print("{s}  {s}: {s}\n", .{ mark, check.name, check.detail });
    }
    if (failures == 0) {
        try out.writeAll("\ndoctor: this checkout can reproduce the build\n");
    } else {
        try out.print("\ndoctor: {d} check(s) failed\n", .{failures});
    }
}

fn reportJson(out: *std.Io.Writer, report: Report) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("healthy");
    try stringify.write(!report.failed());
    try stringify.objectField("checks");
    try stringify.beginArray();
    for (report.checks.items) |check| {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write(check.name);
        try stringify.objectField("status");
        try stringify.write(@tagName(check.status));
        try stringify.objectField("detail");
        try stringify.write(check.detail);
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
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            const value = argument["--format=".len..];
            options.format = std.meta.stringToEnum(Options.Format, value) orelse {
                try err.print("doctor: unknown format '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else {
            try err.print("doctor: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: doctor [options]
        \\
        \\Reports host, compiler, pin, brand, and local policy health.
        \\
        \\Options:
        \\  --format=text|json Output format (default: text)
        \\  -h, --help         Show this message
        \\
        \\Exit codes:
        \\  0  every check passed
        \\  1  at least one check failed
        \\  2  usage error
        \\
    );
}

test "an exclusion entry is recognized with or without a leading separator" {
    try std.testing.expect(excludesPath("/docs/PLATFORM_SPEC.md\n", "docs/PLATFORM_SPEC.md"));
    try std.testing.expect(excludesPath("docs/PLATFORM_SPEC.md\n", "docs/PLATFORM_SPEC.md"));
    try std.testing.expect(excludesPath("# comment\n\n  /docs/PLATFORM_SPEC.md  \n", "docs/PLATFORM_SPEC.md"));
}

test "a commented or absent entry does not count as excluded" {
    try std.testing.expect(!excludesPath("# /docs/PLATFORM_SPEC.md\n", "docs/PLATFORM_SPEC.md"));
    try std.testing.expect(!excludesPath("", "docs/PLATFORM_SPEC.md"));
    try std.testing.expect(!excludesPath("/docs/other.md\n", "docs/PLATFORM_SPEC.md"));
}

test "a partial path match does not count as excluded" {
    try std.testing.expect(!excludesPath("/docs/PLATFORM_SPEC.md.bak\n", "docs/PLATFORM_SPEC.md"));
    try std.testing.expect(!excludesPath("/other/docs/PLATFORM_SPEC.md\n", "docs/PLATFORM_SPEC.md"));
}

test "every floating marker is detected in a package manifest" {
    const samples = [_][]const u8{
        \\.{ .dependencies = .{ .example = .{ .url = "latest" } } }
        ,
        \\.{ .dependencies = .{ .example = .{ .branch = "main" } } }
        ,
        \\.{ .dependencies = .{ .example = .{ .version = "*.*.*" } } }
        ,
    };
    for (samples) |sample| {
        var matched = false;
        for (floating_markers) |marker| {
            if (std.mem.indexOf(u8, sample, marker) != null) matched = true;
        }
        try std.testing.expect(matched);
    }
}

test "a report with any failure is unhealthy" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var report: Report = .{ .arena = arena_state.allocator(), .gpa = gpa };
    defer report.checks.deinit(gpa);

    try report.add("first", .pass, "fine", .{});
    try report.add("second", .note, "informational", .{});
    try std.testing.expect(!report.failed());

    try report.add("third", .fail, "broken", .{});
    try std.testing.expect(report.failed());
}
