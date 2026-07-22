//! Compiler qualification for the supported Zig lines.
//!
//! Zig is pre-1.0 and its stable releases intentionally change language,
//! standard-library, and build-system APIs. Multi-version support is therefore
//! an explicit architecture rather than an assumption that one source file
//! compiles unchanged forever: everything that differs by compiler line lives
//! under `compat/zig/<line>/`, and everything else stays compiler-neutral.
//!
//! This module answers one question — which line is running, and is that line
//! qualified — without knowing anything about the domain. It must not grow
//! business, security, capability, task, or protocol logic.

const std = @import("std");
const builtin = @import("builtin");

/// A supported minor line. Patch releases within a line share adapters; the
/// exact patch a build is pinned to lives in `toolchain.lock.json`.
pub const Line = enum {
    @"0_14",
    @"0_15",
    @"0_16",

    pub fn minor(line: Line) u32 {
        return switch (line) {
            .@"0_14" => 14,
            .@"0_15" => 15,
            .@"0_16" => 16,
        };
    }
};

pub const Qualification = enum {
    /// Development and release baseline. Every gate must pass here.
    canonical,
    /// Adapters are not implemented or the lane is not green. The build fails
    /// closed rather than claiming support it cannot demonstrate.
    unqualified,
};

/// Oldest release the project accepts. Support below this is out of scope.
pub const floor: std.SemanticVersion = .{ .major = 0, .minor = 14, .patch = 1 };

/// Development and release baseline.
pub const canonical: std.SemanticVersion = .{ .major = 0, .minor = 16, .patch = 0 };

/// Maps a compiler version onto a supported line.
///
/// Returns null for anything outside the supported window and for every
/// prerelease. A development snapshot such as `0.17.0-dev.1+abcdef` carries
/// prerelease metadata and never maps onto a line, so it can never enter the
/// matrix by looking numerically close to a stable release.
pub fn lineOf(version: std.SemanticVersion) ?Line {
    if (version.pre != null) return null;
    if (version.major != 0) return null;
    if (version.order(floor) == .lt) return null;
    return switch (version.minor) {
        14 => .@"0_14",
        15 => .@"0_15",
        16 => .@"0_16",
        else => null,
    };
}

/// A line is qualified only when its adapters exist and its complete lane is
/// green. Promoting a line is a deliberate change to this function accompanied
/// by the adapters and the passing lane, never an optimistic edit.
pub fn qualificationOf(line: Line) Qualification {
    return switch (line) {
        .@"0_16" => .canonical,
        .@"0_14", .@"0_15" => .unqualified,
    };
}

pub const current_version = builtin.zig_version;
pub const current_line = lineOf(current_version);
pub const current_qualification: Qualification =
    if (current_line) |line| qualificationOf(line) else .unqualified;

test "the canonical line is qualified" {
    try std.testing.expectEqual(Qualification.canonical, qualificationOf(lineOf(canonical).?));
}

test "the floor release maps onto the oldest line" {
    try std.testing.expectEqual(Line.@"0_14", lineOf(floor).?);
}

test "releases below the floor are out of scope" {
    try std.testing.expectEqual(@as(?Line, null), lineOf(.{ .major = 0, .minor = 14, .patch = 0 }));
    try std.testing.expectEqual(@as(?Line, null), lineOf(.{ .major = 0, .minor = 13, .patch = 0 }));
}

test "a release above the supported window is not assumed compatible" {
    try std.testing.expectEqual(@as(?Line, null), lineOf(.{ .major = 0, .minor = 17, .patch = 0 }));
    try std.testing.expectEqual(@as(?Line, null), lineOf(.{ .major = 1, .minor = 0, .patch = 0 }));
}

test "development snapshots never enter the matrix" {
    const snapshots = [_][]const u8{
        "0.17.0-dev.1+abcdef",
        "0.16.0-dev.100+000000",
        "0.15.2-rc.1",
        "0.14.1-beta",
    };
    for (snapshots) |text| {
        const version = try std.SemanticVersion.parse(text);
        try std.testing.expectEqual(@as(?Line, null), lineOf(version));
    }
}

test "the compiler running this test is qualified" {
    // The build refuses to configure on an unqualified line. If this fails, the
    // adapters for the running line are missing or its lane is not green.
    try std.testing.expectEqual(Qualification.canonical, current_qualification);
}
