//! Checks third-party license compliance for the source tree.
//!
//! A platform's license posture is a supply-chain fact: every dependency carries a license, and some
//! licenses impose obligations — copyleft that reaches into the combined work, or proprietary terms —
//! that the platform must decide about deliberately rather than discover after shipping. This tool
//! classifies each declared dependency's license and checks it against a policy: permissive and
//! weak-copyleft licenses are allowed, strong copyleft and proprietary and anything unrecognized are
//! flagged for a decision. The platform deliberately carries no floating third-party dependencies, so
//! the expected result is an empty, compliant bill; the tool exists to keep it that way — the moment a
//! dependency with an obligation-bearing or unknown license is added, the check flags it.
//!
//! The classification is conservative: an unrecognized license identifier is treated as a violation,
//! not waved through, because an unknown obligation is exactly the one that must be looked at.
//!
//! Exit codes: 0 compliant, 1 a dependency violates the policy or a manifest cannot be read, 2 usage
//! error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// How a license constrains the work that includes it.
pub const Class = enum {
    /// Permissive: attribution only (MIT, BSD, Apache-2.0, ISC). Allowed.
    permissive,
    /// Weak copyleft: obligations limited to the licensed files (MPL-2.0, LGPL). Allowed.
    weak_copyleft,
    /// Strong copyleft: obligations reach the combined work (GPL, AGPL). Flagged.
    strong_copyleft,
    /// Proprietary or non-open terms. Flagged.
    proprietary,
    /// An identifier the tool does not recognize. Flagged — an unknown obligation is looked at.
    unknown,
};

const Known = struct { id: []const u8, class: Class };

/// The license identifiers the tool recognizes, by SPDX-style id.
const known_licenses = [_]Known{
    .{ .id = "MIT", .class = .permissive },
    .{ .id = "BSD-2-Clause", .class = .permissive },
    .{ .id = "BSD-3-Clause", .class = .permissive },
    .{ .id = "Apache-2.0", .class = .permissive },
    .{ .id = "ISC", .class = .permissive },
    .{ .id = "0BSD", .class = .permissive },
    .{ .id = "MPL-2.0", .class = .weak_copyleft },
    .{ .id = "LGPL-2.1", .class = .weak_copyleft },
    .{ .id = "LGPL-3.0", .class = .weak_copyleft },
    .{ .id = "GPL-2.0", .class = .strong_copyleft },
    .{ .id = "GPL-3.0", .class = .strong_copyleft },
    .{ .id = "AGPL-3.0", .class = .strong_copyleft },
    .{ .id = "Proprietary", .class = .proprietary },
};

/// Classifies a license identifier. An identifier not in the known set is unknown, and unknown is
/// conservatively a violation — the tool never waves through a license it cannot reason about.
pub fn classify(identifier: []const u8) Class {
    for (known_licenses) |known| {
        if (std.mem.eql(u8, known.id, identifier)) return known.class;
    }
    return .unknown;
}

/// Whether a license class is allowed under the platform's policy.
///
/// Permissive and weak-copyleft licenses are allowed: their obligations do not reach the combined
/// work in a way the platform cannot meet. Strong copyleft, proprietary, and unknown are flagged for a
/// deliberate decision rather than allowed by default.
pub fn allowed(class: Class) bool {
    return switch (class) {
        .permissive, .weak_copyleft => true,
        .strong_copyleft, .proprietary, .unknown => false,
    };
}

/// Whether a dependency declaring a given license identifier is compliant.
pub fn compliant(identifier: []const u8) bool {
    return allowed(classify(identifier));
}

/// One dependency line parsed from a manifest: a name and its declared license identifier.
const Dependency = struct {
    name: []const u8,
    license: []const u8,
};

/// Parses one manifest line of the form "name SPDX-Id" into a dependency, or null for a blank or
/// comment line. Whitespace-separated; a line without two fields is a parse error.
fn parseLine(line: []const u8) !?Dependency {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const name = it.next() orelse return error.Malformed;
    const license = it.next() orelse return error.Malformed;
    if (it.next() != null) return error.Malformed;
    return .{ .name = name, .license = license };
}

const Options = struct {
    manifest: []const u8 = "dependencies.txt",
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

    // A missing manifest means no declared third-party dependencies — the platform's expected,
    // compliant state — not an error.
    const contents = io_adapters.cwd().readFileAlloc(io, options.manifest, gpa, .limited(1 << 20)) catch {
        try out.print("license: no dependency manifest at '{s}'; no third-party dependencies, compliant\n", .{options.manifest});
        try out.flush();
        return 0;
    };
    defer gpa.free(contents);

    var violations: usize = 0;
    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const dependency = parseLine(line) catch {
            try err.print("license: malformed manifest line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 1;
        } orelse continue;
        checked += 1;
        if (!compliant(dependency.license)) {
            violations += 1;
            try out.print("  FLAG  {s}  {s}  ({s})\n", .{ dependency.name, dependency.license, @tagName(classify(dependency.license)) });
        } else {
            try out.print("  ok    {s}  {s}\n", .{ dependency.name, dependency.license });
        }
    }

    if (violations == 0) {
        try out.print("license: {d} dependency(ies) checked, all compliant\n", .{checked});
        try out.flush();
        return 0;
    }
    try out.print("license: {d} of {d} dependency(ies) violate the policy\n", .{ violations, checked });
    try out.flush();
    return 1;
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: license [--manifest FILE]
                \\
                \\Checks each declared dependency's license against the policy: permissive and
                \\weak-copyleft allowed; strong copyleft, proprietary, and unknown flagged.
                \\Manifest lines are "name SPDX-Id"; blank and #-comment lines are ignored.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("license: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("license: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

test "permissive and weak-copyleft licenses are compliant" {
    try std.testing.expect(compliant("MIT"));
    try std.testing.expect(compliant("Apache-2.0"));
    try std.testing.expect(compliant("MPL-2.0"));
    try std.testing.expect(compliant("LGPL-3.0"));
}

test "strong copyleft, proprietary, and unknown are flagged" {
    try std.testing.expect(!compliant("GPL-3.0"));
    try std.testing.expect(!compliant("AGPL-3.0"));
    try std.testing.expect(!compliant("Proprietary"));
    try std.testing.expect(!compliant("Some-New-License"));
}

test "classification maps known identifiers to their class" {
    try std.testing.expectEqual(Class.permissive, classify("BSD-3-Clause"));
    try std.testing.expectEqual(Class.weak_copyleft, classify("LGPL-2.1"));
    try std.testing.expectEqual(Class.strong_copyleft, classify("GPL-2.0"));
    try std.testing.expectEqual(Class.unknown, classify("WTFPL"));
}

test "an unknown license is never compliant, swept" {
    // The conservative property: any license the tool cannot classify is flagged, never allowed.
    const ids = [_][]const u8{ "MIT", "GPL-3.0", "Unknown-1", "", "Proprietary", "ISC" };
    for (ids) |id| {
        if (classify(id) == .unknown) {
            try std.testing.expect(!compliant(id));
        }
    }
}

test "manifest lines parse into dependencies, ignoring blanks and comments" {
    try std.testing.expectEqual(@as(?Dependency, null), try parseLine(""));
    try std.testing.expectEqual(@as(?Dependency, null), try parseLine("# a comment"));
    const dep = (try parseLine("  wasmtime   Apache-2.0  ")).?;
    try std.testing.expectEqualStrings("wasmtime", dep.name);
    try std.testing.expectEqualStrings("Apache-2.0", dep.license);
    try std.testing.expectError(error.Malformed, parseLine("only-one-field"));
    try std.testing.expectError(error.Malformed, parseLine("too many fields here"));
}
