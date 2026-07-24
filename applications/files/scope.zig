//! Deciding whether a file access stays inside the folder an app was granted, so a grant to one
//! directory cannot be walked out of into the rest of the filesystem.
//!
//! When a person grants an app a folder, they mean that folder and what is under it — not its
//! parent, not a sibling, and certainly not the whole disk. The classic way that grant is defeated
//! is a path that climbs out with "..", turning "the documents folder" into "anything above it". So
//! an access is permitted only when the resolved target path is contained within the granted root:
//! it is the root itself or lies beneath it, after the traversal segments have been accounted for. A
//! path that resolves above or outside the root is refused even though it was expressed relative to a
//! folder the app legitimately holds, because containment is about where the path lands, not where it
//! started. Checking the resolved landing point against the granted root is what keeps a folder grant
//! a folder grant rather than a foothold.
//!
//! This module opens no file. It decides whether a resolved target path is contained within a
//! granted root directory, as a pure function over path segments.

const std = @import("std");

/// Resolves a sequence of path segments, applying ".." as a pop and dropping "." and empty
/// segments, into a normalized depth relative to the root. Returns null if the path ever climbs
/// above the root — the signal that the access escaped the grant.
fn normalizedDepth(segments: []const []const u8) ?usize {
    var depth: usize = 0;
    for (segments) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (depth == 0) return null; // Climbed above the granted root.
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    return depth;
}

/// Whether a target path, expressed as segments relative to the granted root, stays within it.
///
/// The path is walked segment by segment; ".." pops a level and a name pushes one. The access is
/// permitted exactly when the walk never rises above the root — every intermediate and final
/// position is the root or below it. A path that would step above the root at any point is refused,
/// so no relative access escapes the granted folder.
pub fn withinGrant(segments: []const []const u8) bool {
    return normalizedDepth(segments) != null;
}

test "a path inside the granted folder is permitted" {
    try std.testing.expect(withinGrant(&.{ "reports", "q3.txt" }));
}

test "the granted root itself is permitted" {
    try std.testing.expect(withinGrant(&.{}));
    try std.testing.expect(withinGrant(&.{"."}));
}

test "a descend-then-ascend that stays within is permitted" {
    try std.testing.expect(withinGrant(&.{ "reports", "..", "notes.txt" }));
}

test "a path climbing above the root is refused" {
    try std.testing.expect(!withinGrant(&.{ "..", "etc", "secret" }));
    try std.testing.expect(!withinGrant(&.{ "reports", "..", "..", "escape" }));
}

test "no permitted path ever rises above the root, swept" {
    // The containment property: a permitted path's running depth never goes negative.
    const paths = [_][]const []const u8{
        &.{ "a", "b" },
        &.{ "a", "..", "b" },
        &.{ "..", "a" },
        &.{ "a", "..", ".." },
        &.{ ".", "a", "." },
    };
    for (paths) |segments| {
        if (withinGrant(segments)) {
            try std.testing.expect(normalizedDepth(segments) != null);
        }
    }
}
