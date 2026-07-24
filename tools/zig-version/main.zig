//! Decides whether a compiler version is the pinned, canonical one, rejecting prereleases.
//!
//! The build's reproducibility rests on everyone compiling with the same compiler. A version that is
//! close but not equal — a patch newer, a prerelease of the next line — can change generated code in
//! ways no source review would catch, so "close enough" is not enough: the running compiler must be the
//! exact pinned version. This tool decides that. It parses a semantic version and compares it, field by
//! field, against the pin, and it rejects any prerelease outright — a development snapshot carries
//! prerelease metadata and must never be treated as the release it is a snapshot toward, because a
//! prerelease of a version is not that version. An exact match with no prerelease tag passes; anything
//! else fails with the reason. Deciding this by construction rather than by convention is what lets the
//! rest of the toolchain assume the compiler under it is the one the lock file names.
//!
//! Exit codes: 0 the version is the pinned canonical one, 1 it is not, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// A semantic version: major.minor.patch, with a flag for whether it carried prerelease metadata.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: bool,

    /// Whether two versions are equal in all three numeric fields and both are non-prerelease.
    pub fn matches(version: Version, pin: Version) bool {
        return !version.prerelease and !pin.prerelease and
            version.major == pin.major and version.minor == pin.minor and version.patch == pin.patch;
    }
};

/// Why a version was rejected.
pub const Rejection = enum {
    /// The version carries prerelease metadata; a prerelease is never the release.
    prerelease,
    /// The version's numbers do not equal the pin.
    mismatch,
};

/// The decision.
pub const Decision = union(enum) {
    ok,
    rejected: Rejection,

    pub fn accepted(decision: Decision) bool {
        return decision == .ok;
    }
};

/// Decides whether a version is the pinned canonical one.
///
/// A prerelease is rejected first and unconditionally — it is a snapshot toward a version, not the
/// version. A non-prerelease version is accepted only when its numbers equal the pin exactly. Any other
/// case is a mismatch.
pub fn decide(version: Version, pin: Version) Decision {
    if (version.prerelease) return .{ .rejected = .prerelease };
    if (!version.matches(pin)) return .{ .rejected = .mismatch };
    return .ok;
}

/// Parses a semantic version like "0.16.0" or "0.17.0-dev.123+abc". A prerelease ("-…") or build
/// ("+…") suffix sets the prerelease flag; the numeric core must be three dot-separated integers.
pub fn parse(text: []const u8) !Version {
    // Split off any build metadata, then any prerelease.
    var core = text;
    var prerelease = false;
    if (std.mem.indexOfScalar(u8, core, '+')) |plus| {
        core = core[0..plus];
        prerelease = true; // Build metadata is treated as non-canonical.
    }
    if (std.mem.indexOfScalar(u8, core, '-')) |dash| {
        core = core[0..dash];
        prerelease = true;
    }
    var fields = std.mem.splitScalar(u8, core, '.');
    const major = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.Malformed, 10);
    const minor = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.Malformed, 10);
    const patch = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.Malformed, 10);
    if (fields.next() != null) return error.Malformed;
    return .{ .major = major, .minor = minor, .patch = patch, .prerelease = prerelease };
}

/// The pinned canonical compiler version. Kept here as the single source the tool compares against;
/// the toolchain lock file is the authority a review reconciles this with.
pub const canonical_pin: Version = .{ .major = 0, .minor = 16, .patch = 0, .prerelease = false };

const Options = struct {
    version_text: []const u8 = "",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buffer: [8 * 1024]u8 = undefined;
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

    if (options.version_text.len == 0) {
        try err.print("zig-version: --version is required\n", .{});
        try err.flush();
        return 2;
    }

    const version = parse(options.version_text) catch {
        try err.print("zig-version: not a semantic version: '{s}'\n", .{options.version_text});
        try err.flush();
        return 2;
    };

    switch (decide(version, canonical_pin)) {
        .ok => {
            try out.print("zig-version: {s} is the pinned canonical compiler\n", .{options.version_text});
            try out.flush();
            return 0;
        },
        .rejected => |reason| {
            try out.print("zig-version: {s} rejected ({s}; pin is {d}.{d}.{d})\n", .{
                options.version_text, describe(reason), canonical_pin.major, canonical_pin.minor, canonical_pin.patch,
            });
            try out.flush();
            return 1;
        },
    }
}

fn describe(reason: Rejection) []const u8 {
    return switch (reason) {
        .prerelease => "a prerelease is never the release",
        .mismatch => "does not match the pin",
    };
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: zig-version --version X.Y.Z
                \\
                \\Decides whether a compiler version is the pinned canonical one. An exact
                \\major.minor.patch match with no prerelease metadata passes; a prerelease or a
                \\different version fails.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version")) {
            index += 1;
            if (index >= args.len) {
                try err.print("zig-version: --version needs a value\n", .{});
                return error.InvalidArguments;
            }
            options.version_text = args[index];
        } else {
            try err.print("zig-version: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

test "the exact pinned version is accepted" {
    try std.testing.expect(decide(canonical_pin, canonical_pin).accepted());
    try std.testing.expect(decide(try parse("0.16.0"), canonical_pin).accepted());
}

test "a different version is a mismatch" {
    try std.testing.expectEqual(Decision{ .rejected = .mismatch }, decide(try parse("0.15.2"), canonical_pin));
    try std.testing.expectEqual(Decision{ .rejected = .mismatch }, decide(try parse("0.16.1"), canonical_pin));
}

test "a prerelease is rejected even if its numbers match" {
    try std.testing.expectEqual(Decision{ .rejected = .prerelease }, decide(try parse("0.16.0-dev.1"), canonical_pin));
    try std.testing.expectEqual(Decision{ .rejected = .prerelease }, decide(try parse("0.17.0-dev.99"), canonical_pin));
}

test "parsing splits the numeric core from prerelease and build metadata" {
    const v = try parse("0.17.0-dev.123+abcdef");
    try std.testing.expectEqual(@as(u32, 0), v.major);
    try std.testing.expectEqual(@as(u32, 17), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
    try std.testing.expect(v.prerelease);
    try std.testing.expectError(error.Malformed, parse("0.16"));
    try std.testing.expectError(error.Malformed, parse("0.16.0.1"));
}

test "no accepted version is ever a prerelease, swept" {
    // The prerelease-never-passes property: an accepted version has no prerelease metadata.
    const texts = [_][]const u8{ "0.16.0", "0.16.0-dev.1", "0.16.1", "0.15.2", "0.16.0+meta" };
    for (texts) |text| {
        const version = try parse(text);
        if (decide(version, canonical_pin).accepted()) {
            try std.testing.expect(!version.prerelease);
        }
    }
}
