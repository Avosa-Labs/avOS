//! Resolving an SDK example by name from a closed registry, so a developer opens a real, maintained
//! example rather than a broken link to one that was renamed or removed.
//!
//! The SDK ships examples — small working apps a developer opens to learn a feature — and they are
//! referenced by name from documentation and the tooling. Those references are only useful if every
//! name resolves to an example that actually exists and builds, so the registry is closed: a name
//! either maps to a maintained example or it does not resolve at all. A closed registry keeps the
//! docs honest — a link to an example is guaranteed to lead somewhere real, because a name not in the
//! registry is a caught error rather than a dead link — and it makes renaming an example a
//! deliberate act that updates the registry, not a silent break of every reference to the old name.
//! Resolving from a closed set is the small discipline that keeps the examples a developer relies on
//! from rotting into broken links.
//!
//! This module opens no example. It resolves an example name to its path from a closed registry, as
//! a pure function.

const std = @import("std");

/// One example in the registry.
pub const Example = struct {
    name: []const u8,
    path: []const u8,
};

/// The closed set of maintained examples. A name absent from it does not resolve.
const registry = [_]Example{
    .{ .name = "hello-agent", .path = "examples/hello-agent" },
    .{ .name = "todo-app", .path = "examples/todo-app" },
    .{ .name = "camera-capture", .path = "examples/camera-capture" },
};

/// Resolves an example name to its path, or null if the name is not in the registry.
pub fn resolve(name: []const u8) ?[]const u8 {
    for (registry) |example| {
        if (std.mem.eql(u8, example.name, name)) return example.path;
    }
    return null;
}

/// Whether a name is a known example.
pub fn has(name: []const u8) bool {
    return resolve(name) != null;
}

test "a known example resolves to its path" {
    try std.testing.expectEqualStrings("examples/todo-app", resolve("todo-app").?);
}

test "an unknown name does not resolve" {
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("nonexistent"));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve(""));
}

test "membership is exact" {
    try std.testing.expect(has("hello-agent"));
    try std.testing.expect(!has("hello-agents"));
}

test "every registered example resolves and nothing else does, swept" {
    for (registry) |example| {
        try std.testing.expect(has(example.name));
        try std.testing.expectEqualStrings(example.path, resolve(example.name).?);
    }
    try std.testing.expect(!has("not.an.example"));
}
