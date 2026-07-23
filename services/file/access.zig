//! Deciding whether an app may touch a file, confining each app to the directories
//! it was granted, so a file broker never lets one app roam another's data.
//!
//! On a device where every app stores files, the filesystem is shared but the trust
//! is not: an app should reach its own data and the specific places a person handed
//! it, and nothing else. Scoped access is how that holds. Each app is granted a set
//! of roots — its own container, a folder the person picked — and a request is
//! permitted only when the path falls within one of those roots and the operation
//! the root allows covers it. A read-only grant does not become a write, and a path
//! that resolves outside every granted root is refused rather than served, because a
//! broker that follows a path wherever it points is a broker that leaks. The path
//! confinement below this stops a path escaping a single root; this decides which
//! roots an app holds at all.
//!
//! This module opens no file. It decides whether an app's request to a resolved path
//! is within one of its grants for the operation it wants, as a pure function over
//! the grant set.

const std = @import("std");

/// What an app may do within a granted root.
pub const Mode = enum {
    /// Read only.
    read,
    /// Read and write.
    read_write,

    fn permits(mode: Mode, operation: Operation) bool {
        return switch (operation) {
            .read => true, // both modes allow reading
            .write => mode == .read_write,
        };
    }
};

/// What an app wants to do to a file.
pub const Operation = enum { read, write };

/// A grant: a root directory an app may access, and how.
pub const Grant = struct {
    /// The root path, already resolved and confined. A request path is within this
    /// grant when it equals the root or descends from it.
    root: []const u8,
    mode: Mode,

    /// Whether a resolved path lies within this grant's root.
    fn contains(grant: Grant, path: []const u8) bool {
        if (std.mem.eql(u8, grant.root, path)) return true;
        // A descendant: the path starts with "root/".
        if (path.len <= grant.root.len) return false;
        if (!std.mem.startsWith(u8, path, grant.root)) return false;
        return path[grant.root.len] == '/';
    }
};

/// Why a file request was refused.
pub const Refusal = enum {
    /// The path is not within any granted root.
    outside_grants,
    /// The path is within a granted root, but the grant does not allow this
    /// operation — a write against a read-only grant.
    operation_not_allowed,
};

/// The outcome of a file request.
pub const Decision = union(enum) {
    allow,
    refuse: Refusal,

    pub fn allowed(decision: Decision) bool {
        return decision == .allow;
    }
};

/// A request to touch a file at a resolved path.
pub const Request = struct {
    path: []const u8,
    operation: Operation,
};

/// Decides whether an app's request is permitted by its grants.
///
/// The path must fall within one of the granted roots, and that root's mode must
/// allow the operation. A path within a matching root but for a disallowed operation
/// is refused as such; a path within no root is refused as outside the grants. The
/// first root that contains the path decides the operation check, so a read-only
/// grant and a read-write grant on nested roots resolve by containment.
pub fn decide(grants: []const Grant, request: Request) Decision {
    var contained = false;
    for (grants) |grant| {
        if (!grant.contains(request.path)) continue;
        contained = true;
        if (grant.mode.permits(request.operation)) return .allow;
    }
    if (contained) return .{ .refuse = .operation_not_allowed };
    return .{ .refuse = .outside_grants };
}

const sample_grants = [_]Grant{
    .{ .root = "/apps/mail/data", .mode = .read_write },
    .{ .root = "/shared/documents", .mode = .read },
};

fn req(path: []const u8, operation: Operation) Request {
    return .{ .path = path, .operation = operation };
}

test "an app reads and writes within its own container" {
    try std.testing.expect(decide(&sample_grants, req("/apps/mail/data/inbox.db", .read)).allowed());
    try std.testing.expect(decide(&sample_grants, req("/apps/mail/data/inbox.db", .write)).allowed());
}

test "a read-only grant refuses a write" {
    try std.testing.expect(decide(&sample_grants, req("/shared/documents/report.txt", .read)).allowed());
    try std.testing.expectEqual(
        Decision{ .refuse = .operation_not_allowed },
        decide(&sample_grants, req("/shared/documents/report.txt", .write)),
    );
}

test "a path outside every grant is refused" {
    try std.testing.expectEqual(
        Decision{ .refuse = .outside_grants },
        decide(&sample_grants, req("/apps/other/data/secret", .read)),
    );
}

test "the grant root itself is within the grant" {
    try std.testing.expect(decide(&sample_grants, req("/apps/mail/data", .read)).allowed());
}

test "a sibling directory sharing a prefix is not within the grant" {
    // "/apps/mail/data-backup" shares the prefix "/apps/mail/data" but is not inside
    // it; the boundary is the path separator.
    try std.testing.expectEqual(
        Decision{ .refuse = .outside_grants },
        decide(&sample_grants, req("/apps/mail/data-backup/x", .read)),
    );
}

test "an empty grant set permits nothing" {
    try std.testing.expectEqual(Decision{ .refuse = .outside_grants }, decide(&.{}, req("/anything", .read)));
}

test "no request outside a granted root is ever allowed, swept" {
    // The confinement property: an allowed request always lies within some grant.
    const paths = [_][]const u8{
        "/apps/mail/data/x",      "/shared/documents/y", "/apps/other/z",
        "/apps/mail/data-backup", "/",                   "/shared",
    };
    for (paths) |path| {
        for ([_]Operation{ .read, .write }) |operation| {
            if (decide(&sample_grants, req(path, operation)).allowed()) {
                var within = false;
                for (sample_grants) |grant| {
                    if (grant.contains(path)) within = true;
                }
                try std.testing.expect(within);
            }
        }
    }
}
