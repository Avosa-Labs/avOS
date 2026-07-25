//! Per-application isolated storage: each Android application sees only its own
//! storage root, and a path that would escape it is refused, so one application can
//! never read or write another's data.
//!
//! Android's own model gives each application a private data directory, and the host
//! must preserve that isolation rather than hand every application a shared
//! filesystem. Each application is given a root, derived from its identity, and every
//! path it opens is resolved within that root. The threat is not only naming another
//! application's directory outright — it is escaping one's own with a traversal, a
//! `..` that climbs out of the sandbox into a sibling's data or the host's. So a path
//! is admitted only if, after resolution, it still lies under the application's root;
//! anything that escapes is refused before it reaches the real filesystem. Isolation
//! that holds only for well-formed paths is not isolation, so the escape check is the
//! point of this module, not an aside.
//!
//! It resolves and validates paths against a root; it opens no file. The actual read
//! and write are the host's, on a path this module has confirmed stays inside the
//! application's own space.

const std = @import("std");
const core = @import("core");

const identity = core.identity;

pub const Error = error{
    /// The path escapes the application's storage root — an absolute path or a
    /// traversal that climbs above the root.
    PathEscapesRoot,
    /// The path is empty, which names nothing to open.
    EmptyPath,
};

/// An application's private storage, rooted at a directory only it can reach.
pub const Storage = struct {
    /// The principal whose storage this is. The root is its and no one else's.
    owner: identity.PrincipalId,
    /// The absolute root directory, e.g. "/data/app/<id>". Every opened path resolves
    /// within this.
    root: []const u8,

    /// Confirms a relative path stays within the root and returns its normalized
    /// form relative to the root, or refuses a path that would escape.
    ///
    /// The path is walked segment by segment, maintaining a depth below the root. A
    /// `..` that would take the depth negative escapes the root and is refused; an
    /// absolute path is refused outright, since it names a location the root does not
    /// contain. `.` and empty segments are skipped. What returns is a path that is
    /// guaranteed to lie within the application's own storage.
    pub fn resolve(storage: Storage, path: []const u8, buffer: []u8) Error![]const u8 {
        _ = storage;
        if (path.len == 0) return error.EmptyPath;
        // An absolute path names outside the root by definition.
        if (path[0] == '/') return error.PathEscapesRoot;

        var depth: usize = 0;
        var written: usize = 0;
        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                // Climbing above the root is an escape.
                if (depth == 0) return error.PathEscapesRoot;
                depth -= 1;
                // Trim the last written segment.
                written = trimLastSegment(buffer[0..written]);
                continue;
            }
            if (written != 0) {
                if (written >= buffer.len) return error.PathEscapesRoot;
                buffer[written] = '/';
                written += 1;
            }
            if (written + segment.len > buffer.len) return error.PathEscapesRoot;
            @memcpy(buffer[written .. written + segment.len], segment);
            written += segment.len;
            depth += 1;
        }
        return buffer[0..written];
    }

    /// Whether a path stays within the application's storage, without producing the
    /// resolved form. For a caller that only needs the yes-or-no.
    pub fn contains(storage: Storage, path: []const u8) bool {
        var buffer: [1024]u8 = undefined;
        _ = storage.resolve(path, &buffer) catch return false;
        return true;
    }
};

fn trimLastSegment(written: []const u8) usize {
    var index = written.len;
    while (index > 0 and written[index - 1] != '/') index -= 1;
    // Drop the trailing slash too, if any.
    if (index > 0) index -= 1;
    return index;
}

// --- Tests ---

const testing = std.testing;

fn storageFor(value: u128) Storage {
    return .{ .owner = .{ .value = value }, .root = "/data/app/example" };
}

test "a plain relative path resolves within the root" {
    const storage = storageFor(1);
    var buffer: [256]u8 = undefined;
    const confined = try storage.resolve("documents/notes.txt", &buffer);
    try testing.expectEqualStrings("documents/notes.txt", confined);
}

test "a traversal that escapes the root is refused" {
    const storage = storageFor(1);
    var buffer: [256]u8 = undefined;
    try testing.expectError(error.PathEscapesRoot, storage.resolve("../other-app/secrets", &buffer));
    try testing.expectError(error.PathEscapesRoot, storage.resolve("documents/../../escape", &buffer));
    try testing.expect(!storage.contains("../elsewhere"));
}

test "an absolute path is refused" {
    const storage = storageFor(1);
    var buffer: [256]u8 = undefined;
    try testing.expectError(error.PathEscapesRoot, storage.resolve("/etc/passwd", &buffer));
}

test "a traversal that stays within the root is allowed" {
    const storage = storageFor(1);
    var buffer: [256]u8 = undefined;
    // Into a subdir and back out, netting a sibling file — still inside the root.
    const confined = try storage.resolve("documents/../cache/thumb.png", &buffer);
    try testing.expectEqualStrings("cache/thumb.png", confined);
}

test "redundant separators and dot segments are normalized away" {
    const storage = storageFor(1);
    var buffer: [256]u8 = undefined;
    const confined = try storage.resolve("./documents//./notes.txt", &buffer);
    try testing.expectEqualStrings("documents/notes.txt", confined);
}

test "an empty path names nothing" {
    const storage = storageFor(1);
    var buffer: [16]u8 = undefined;
    try testing.expectError(error.EmptyPath, storage.resolve("", &buffer));
}
