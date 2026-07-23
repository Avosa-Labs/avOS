//! Resolving a path within a root without letting it escape, so a component that
//! holds untrusted data cannot reach a file outside the tree it was confined to.
//!
//! A path is the classic way a confinement is broken. A service is given a root —
//! an app's own data directory, a sandbox, a download folder — and told to resolve
//! names within it, and if resolution follows "../" wherever it leads, then a name
//! that came from untrusted input, "../../etc/keys", walks straight out of the root
//! into files that were never meant to be reachable. The defence is not to strip or
//! rewrite the dangerous part, because silently turning "../../secret" into
//! "root/secret" hides the attempt and may still hit a real file; it is to resolve
//! the path honestly and refuse the moment it would rise above the root. A ".."
//! that pops the root's own floor is an escape, and an escape is an error.
//!
//! This module touches no filesystem. It walks a path's components against a root,
//! collapsing "." and "..", and decides whether the result stays within the root —
//! reporting the resolved depth when it does and refusing when a component would
//! escape or is itself malformed — as a pure function over the path text.

const std = @import("std");

/// The longest single path component the resolver accepts. A component longer than
/// this is refused rather than processed, so a name cannot itself become a resource.
pub const max_component_bytes: usize = 255;

/// The deepest a resolved path may nest below its root. Bounds the work and the
/// structures the layers above must size for.
pub const max_depth: usize = 64;

/// Why a path was refused.
pub const Refusal = enum {
    /// A ".." would rise above the root: the path escapes its confinement. Refused
    /// rather than clamped, so the attempt is visible and never lands on a real
    /// file outside the root.
    escapes_root,
    /// A component is longer than the resolver accepts.
    component_too_long,
    /// A component contains a NUL byte, which truncates a path in the C APIs
    /// beneath and is never part of a legitimate name.
    invalid_component,
    /// The path nests deeper than the resolver allows.
    too_deep,
};

/// The outcome of resolving a path.
pub const Resolution = union(enum) {
    /// The path stays within the root, at this depth below it (zero being the root
    /// itself).
    resolved: usize,
    /// The path is refused.
    refuse: Refusal,

    pub fn ok(resolution: Resolution) bool {
        return resolution == .resolved;
    }
};

/// Resolves a path against its root, deciding whether it stays inside.
///
/// Components are walked in order. A leading slash and empty components (from "//"
/// or a trailing slash) are ignored, so the path is treated as relative to the
/// root however it is punctuated. "." holds the current position; ".." rises one
/// level, and if that would rise above the root the path is refused as an escape
/// rather than clamped to the root. A named component descends one level, checked
/// for length and for a NUL byte first. The resolved depth is reported so the
/// caller knows where within the root the path landed.
pub fn resolve(path: []const u8) Resolution {
    var depth: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            // Rising above the root is an escape, not a no-op at the floor.
            if (depth == 0) return .{ .refuse = .escapes_root };
            depth -= 1;
            continue;
        }
        if (component.len > max_component_bytes) return .{ .refuse = .component_too_long };
        if (std.mem.indexOfScalar(u8, component, 0) != null) return .{ .refuse = .invalid_component };
        depth += 1;
        if (depth > max_depth) return .{ .refuse = .too_deep };
    }
    return .{ .resolved = depth };
}

/// Whether a path resolves within its root.
pub fn isWithinRoot(path: []const u8) bool {
    return resolve(path).ok();
}

test "a simple path resolves to its depth" {
    try std.testing.expectEqual(Resolution{ .resolved = 2 }, resolve("photos/summer"));
    try std.testing.expectEqual(Resolution{ .resolved = 1 }, resolve("notes.txt"));
}

test "the root itself resolves to depth zero" {
    try std.testing.expectEqual(Resolution{ .resolved = 0 }, resolve(""));
    try std.testing.expectEqual(Resolution{ .resolved = 0 }, resolve("."));
    try std.testing.expectEqual(Resolution{ .resolved = 0 }, resolve("/"));
}

test "punctuation is normalized: leading, trailing, and doubled slashes" {
    try std.testing.expectEqual(Resolution{ .resolved = 2 }, resolve("/photos/summer"));
    try std.testing.expectEqual(Resolution{ .resolved = 2 }, resolve("photos/summer/"));
    try std.testing.expectEqual(Resolution{ .resolved = 2 }, resolve("photos//summer"));
}

test "a dot component holds position" {
    try std.testing.expectEqual(Resolution{ .resolved = 2 }, resolve("photos/./summer"));
}

test "a dotdot within the tree rises one level" {
    // photos/summer/.. is photos, depth 1.
    try std.testing.expectEqual(Resolution{ .resolved = 1 }, resolve("photos/summer/.."));
    // Down, up, down again.
    try std.testing.expectEqual(Resolution{ .resolved = 2 }, resolve("a/b/../c"));
}

test "a dotdot above the root is refused as an escape, not clamped" {
    try std.testing.expectEqual(Resolution{ .refuse = .escapes_root }, resolve(".."));
    try std.testing.expectEqual(Resolution{ .refuse = .escapes_root }, resolve("../etc/keys"));
    // Descends one then rises two: net above the root.
    try std.testing.expectEqual(Resolution{ .refuse = .escapes_root }, resolve("a/../.."));
}

test "an escape is refused even if it would later descend to a real path" {
    // "../../root/secret" must not be silently resolved to something inside the
    // root; the escape is refused the moment it happens.
    try std.testing.expectEqual(Resolution{ .refuse = .escapes_root }, resolve("../../root/secret"));
}

test "an over-long component is refused" {
    var buf: [max_component_bytes + 1]u8 = @splat('a');
    try std.testing.expectEqual(Resolution{ .refuse = .component_too_long }, resolve(&buf));
}

test "a component with a NUL byte is refused" {
    const sneaky = "photos/sum\x00mer";
    try std.testing.expectEqual(Resolution{ .refuse = .invalid_component }, resolve(sneaky));
}

test "a path deeper than the limit is refused" {
    var buf: [max_depth * 2 + 2]u8 = undefined;
    var end: usize = 0;
    for (0..max_depth + 1) |i| {
        if (i != 0) {
            buf[end] = '/';
            end += 1;
        }
        buf[end] = 'a';
        end += 1;
    }
    try std.testing.expectEqual(Resolution{ .refuse = .too_deep }, resolve(buf[0..end]));
}

test "no path ever resolves above its root, swept" {
    // The confinement property: across a mix of paths, any that resolves lands at
    // a non-negative depth within the root, and every escaping form is refused.
    const escaping = [_][]const u8{ "..", "a/../..", "../x", "x/../../y", "../../../" };
    for (escaping) |path| {
        try std.testing.expect(!isWithinRoot(path));
    }
    const staying = [_][]const u8{ "a", "a/b", "a/b/../c", "./a", "a/", "/a/b" };
    for (staying) |path| {
        try std.testing.expect(isWithinRoot(path));
    }
}
