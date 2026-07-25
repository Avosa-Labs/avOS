//! Files, agent-native: the capabilities an agent browses, edits, and organizes
//! documents through, and the scope rule that confines every access to its grant.
//!
//! Listing and opening are reads an agent does freely; editing and moving are
//! reversible local changes; sharing sends a file outside the device and is held for
//! the person. The capabilities are declared for the planner to discover. The
//! confinement rule stays: an access is allowed only within the granted folder, and a
//! path that climbs out of it is refused, because a file grant that leaks past its
//! folder is not a grant.
//!
//! This module defines the app's capabilities and its scope rule; the shared frame
//! gates, records, and dispatches to the domain.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const tools = [_]framework.Tool{
    .{ .name = "file.list", .required_capability = "files.read", .effect = .read_only },
    .{ .name = "file.open", .required_capability = "files.read", .effect = .read_only },
    .{ .name = "file.edit", .required_capability = "files.write", .effect = .local_mutation },
    .{ .name = "file.move", .required_capability = "files.write", .effect = .local_mutation },
    .{ .name = "file.share", .required_capability = "files.share", .effect = .external },
    .{ .name = "file.delete", .required_capability = "files.write", .effect = .local_mutation },
};

/// Whether a path stays within the granted folder — never absolute, never climbing
/// above its root.
pub fn withinGrant(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var depth: i32 = 0;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            depth -= 1;
            if (depth < 0) return false;
        } else depth += 1;
    }
    return true;
}

const testing = std.testing;

test "a path that escapes the granted folder is outside the grant" {
    try testing.expect(withinGrant("documents/notes.txt"));
    try testing.expect(withinGrant("a/../b/file"));
    try testing.expect(!withinGrant("../other/secrets"));
    try testing.expect(!withinGrant("/etc/passwd"));
}

test "sharing is external and held; listing and editing are the agent's" {
    try testing.expect(tools[4].effect.needsApproval()); // file.share
    try testing.expect(!tools[0].effect.needsApproval()); // file.list
    try testing.expect(!tools[2].effect.needsApproval()); // file.edit
}
