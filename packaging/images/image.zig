//! The system image format.
//!
//! An image is what a device installs: a set of files, a version, and a device
//! class, reduced to a single digest that a signature covers and the boot chain
//! measures. Nothing else about it matters to a device, so nothing else belongs
//! in it.
//!
//! Every field that could vary between two builds of the same source is absent
//! by construction rather than normalized after the fact. There is no build
//! timestamp, no builder identity, no host path, and no ordering that depends
//! on how a directory happened to be walked. A format that recorded any of them
//! would produce a different digest on every machine, and reproducibility would
//! become a claim nobody could check.
//!
//! The digest covers the manifest, and the manifest covers each file's path and
//! contents. A device therefore verifies one signature and gets an answer about
//! every byte it is about to install.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_bytes = Sha256.digest_length;

/// Identifies this image format. A stable technical identifier: changing it is
/// a migration, never a rename.
pub const format_identifier = "image-v1";

/// Longest path an entry may carry.
///
/// Bounded so a manifest cannot be made to describe a path a device cannot
/// hold, and so the encoding has no variable-width length nobody validated.
pub const max_path_bytes: usize = 512;

/// Most entries an image may contain.
pub const max_entries: usize = 4096;

pub const Error = error{
    /// Two entries name the same path. A device would install one and not the
    /// other, and which one would depend on the order they were read.
    DuplicatePath,
    /// A path is empty, absolute, or climbs out of the image root.
    PathNotAllowed,
    /// A path is longer than an entry may carry.
    PathTooLong,
    /// More entries than an image may contain.
    TooManyEntries,
    /// Entries are not in the order the format requires.
    OrderNotCanonical,
};

/// One file in the image.
pub const Entry = struct {
    /// Where the file lands, relative to the image root. Always forward slashes:
    /// a separator that varied by build host would vary the digest.
    path: []const u8,
    digest: [digest_bytes]u8,
    size_bytes: u64,
    /// Whether the file is executable. The only permission bit an image carries,
    /// because it is the only one that changes what a device does.
    executable: bool,
};

/// What the image is.
pub const Identity = struct {
    /// Which hardware this image is built for. A device refuses one built for
    /// another class rather than trying it.
    device_class: []const u8,
    major: u32,
    minor: u32,
    patch: u32,
    /// Raised when a release fixes something that must not be reintroduced.
    security_generation: u32,
};

/// A complete image description.
pub const Manifest = struct {
    identity: Identity,
    /// Sorted by path, ascending, byte-wise. The order is part of the format so
    /// two builds that found the same files produce the same bytes regardless
    /// of how the filesystem enumerated them.
    entries: []const Entry,

    /// Checks everything the format requires before a digest means anything.
    ///
    /// Called before computing a digest rather than after, because a digest over
    /// a manifest that violates the format is a number that describes nothing.
    pub fn validate(manifest: Manifest) Error!void {
        if (manifest.entries.len > max_entries) return error.TooManyEntries;

        var previous: ?[]const u8 = null;
        for (manifest.entries) |entry| {
            if (entry.path.len == 0) return error.PathNotAllowed;
            if (entry.path.len > max_path_bytes) return error.PathTooLong;
            if (entry.path[0] == '/') return error.PathNotAllowed;
            if (std.mem.indexOf(u8, entry.path, "..") != null) return error.PathNotAllowed;
            if (std.mem.indexOfScalar(u8, entry.path, '\\') != null) return error.PathNotAllowed;

            if (previous) |earlier| {
                return switch (std.mem.order(u8, earlier, entry.path)) {
                    .lt => {
                        previous = entry.path;
                        continue;
                    },
                    .eq => error.DuplicatePath,
                    .gt => error.OrderNotCanonical,
                };
            }
            previous = entry.path;
        }
    }

    /// The image's identity as a single value.
    ///
    /// This is what a signature covers and what the boot chain measures. Every
    /// field is length-prefixed, so no two distinct manifests produce the same
    /// bytes by moving a boundary between fields.
    pub fn digest(manifest: Manifest) Error![digest_bytes]u8 {
        try manifest.validate();

        var hash: Sha256 = .init(.{});
        hash.update(format_identifier);
        updateWithString(&hash, manifest.identity.device_class);
        updateWithInteger(&hash, manifest.identity.major);
        updateWithInteger(&hash, manifest.identity.minor);
        updateWithInteger(&hash, manifest.identity.patch);
        updateWithInteger(&hash, manifest.identity.security_generation);
        updateWithInteger(&hash, @intCast(manifest.entries.len));

        for (manifest.entries) |entry| {
            updateWithString(&hash, entry.path);
            hash.update(&entry.digest);
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, entry.size_bytes, .little);
            hash.update(&size);
            hash.update(&[_]u8{@intFromBool(entry.executable)});
        }

        var result: [digest_bytes]u8 = undefined;
        hash.final(&result);
        return result;
    }

    /// Total size of everything the image installs.
    pub fn totalBytes(manifest: Manifest) u64 {
        var total: u64 = 0;
        for (manifest.entries) |entry| total +|= entry.size_bytes;
        return total;
    }
};

fn updateWithString(hash: *Sha256, text: []const u8) void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(text.len), .little);
    hash.update(&length);
    hash.update(text);
}

fn updateWithInteger(hash: *Sha256, value: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

/// Measures a file's contents the way an entry records them.
pub fn digestOf(contents: []const u8) [digest_bytes]u8 {
    var result: [digest_bytes]u8 = undefined;
    Sha256.hash(contents, &result, .{});
    return result;
}

/// Orders two entries the way the format requires.
///
/// Exposed so a builder sorts by the same rule the validator checks, rather than
/// by one that happens to agree today.
pub fn lessThanByPath(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

const sample_identity: Identity = .{
    .device_class = "reference",
    .major = 1,
    .minor = 2,
    .patch = 3,
    .security_generation = 4,
};

fn entryFor(path: []const u8, contents: []const u8, executable: bool) Entry {
    return .{
        .path = path,
        .digest = digestOf(contents),
        .size_bytes = contents.len,
        .executable = executable,
    };
}

test "the same contents produce the same digest" {
    const first: Manifest = .{
        .identity = sample_identity,
        .entries = &.{
            entryFor("bin/control-plane", "the control plane", true),
            entryFor("etc/policy.json", "{}", false),
        },
    };
    const second: Manifest = .{
        .identity = sample_identity,
        .entries = &.{
            entryFor("bin/control-plane", "the control plane", true),
            entryFor("etc/policy.json", "{}", false),
        },
    };

    // The property the whole format exists for: two builds of the same source
    // are the same image, byte for byte.
    try std.testing.expectEqualSlices(u8, &try first.digest(), &try second.digest());
}

test "a change to any file changes the digest" {
    const before: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/control-plane", "the control plane", true)},
    };
    const after: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/control-plane", "a different control plane", true)},
    };
    try std.testing.expect(!std.mem.eql(u8, &try before.digest(), &try after.digest()));
}

test "a change to a path changes the digest" {
    const here: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/control-plane", "the same bytes", true)},
    };
    const there: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/control-plane-2", "the same bytes", true)},
    };
    // Installing the same bytes somewhere else is a different image.
    try std.testing.expect(!std.mem.eql(u8, &try here.digest(), &try there.digest()));
}

test "the executable bit is part of the image" {
    const runnable: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/tool", "contents", true)},
    };
    const inert: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/tool", "contents", false)},
    };
    // It is the one permission bit that changes what a device does, so an image
    // that ignored it would install something that behaves differently.
    try std.testing.expect(!std.mem.eql(u8, &try runnable.digest(), &try inert.digest()));
}

test "every part of the identity is covered" {
    const base: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/tool", "contents", false)},
    };
    const baseline = try base.digest();

    var variants: [5]Identity = @splat(sample_identity);
    variants[0].device_class = "another-board";
    variants[1].major += 1;
    variants[2].minor += 1;
    variants[3].patch += 1;
    variants[4].security_generation += 1;

    for (variants) |identity| {
        const changed: Manifest = .{ .identity = identity, .entries = base.entries };
        try std.testing.expect(!std.mem.eql(u8, &baseline, &try changed.digest()));
    }
}

test "field boundaries cannot be moved to forge a match" {
    // Two manifests whose fields concatenate to the same bytes if lengths are
    // not written. Length prefixes are what stop this.
    const left: Manifest = .{
        .identity = .{
            .device_class = "ab",
            .major = 1,
            .minor = 0,
            .patch = 0,
            .security_generation = 0,
        },
        .entries = &.{entryFor("c", "contents", false)},
    };
    const right: Manifest = .{
        .identity = .{
            .device_class = "a",
            .major = 1,
            .minor = 0,
            .patch = 0,
            .security_generation = 0,
        },
        .entries = &.{entryFor("bc", "contents", false)},
    };
    try std.testing.expect(!std.mem.eql(u8, &try left.digest(), &try right.digest()));
}

test "entries out of order are refused rather than sorted" {
    const manifest: Manifest = .{
        .identity = sample_identity,
        .entries = &.{
            entryFor("etc/policy.json", "{}", false),
            entryFor("bin/control-plane", "the control plane", true),
        },
    };
    // Sorting here would hide a builder that walked the filesystem in whatever
    // order it pleased, and the format would stop being the thing that
    // guarantees the order.
    try std.testing.expectError(error.OrderNotCanonical, manifest.digest());
}

test "a duplicate path is refused" {
    const manifest: Manifest = .{
        .identity = sample_identity,
        .entries = &.{
            entryFor("bin/tool", "one", false),
            entryFor("bin/tool", "another", false),
        },
    };
    // A device would install one and not the other, and which one would depend
    // on the order they were read.
    try std.testing.expectError(error.DuplicatePath, manifest.digest());
}

test "a path that escapes the image root is refused" {
    const refused = [_][]const u8{
        "/etc/passwd",
        "../outside",
        "bin/../../outside",
        "bin\\tool",
        "",
    };
    for (refused) |path| {
        const manifest: Manifest = .{
            .identity = sample_identity,
            .entries = &.{entryFor(path, "contents", false)},
        };
        try std.testing.expect(std.meta.isError(manifest.digest()));
    }
}

test "an image with too many entries is refused" {
    const gpa = std.testing.allocator;
    const entries = try gpa.alloc(Entry, max_entries + 1);
    defer gpa.free(entries);
    for (entries) |*entry| entry.* = entryFor("bin/tool", "contents", false);

    const manifest: Manifest = .{ .identity = sample_identity, .entries = entries };
    try std.testing.expectError(error.TooManyEntries, manifest.digest());
}

test "an empty image still has a digest" {
    const manifest: Manifest = .{ .identity = sample_identity, .entries = &.{} };
    const empty = try manifest.digest();

    // A device must be able to reject it for being empty, which needs a value
    // to reject rather than an absence to interpret.
    const populated: Manifest = .{
        .identity = sample_identity,
        .entries = &.{entryFor("bin/tool", "contents", false)},
    };
    try std.testing.expect(!std.mem.eql(u8, &empty, &try populated.digest()));
    try std.testing.expectEqual(@as(u64, 0), manifest.totalBytes());
}

test "the sort a builder uses is the order the format checks" {
    var entries = [_]Entry{
        entryFor("etc/policy.json", "{}", false),
        entryFor("bin/control-plane", "the control plane", true),
        entryFor("bin/agent", "the agent", true),
    };
    std.mem.sort(Entry, &entries, {}, lessThanByPath);

    const manifest: Manifest = .{ .identity = sample_identity, .entries = &entries };
    _ = try manifest.digest();
}

test "the total size is the sum of what is installed" {
    const manifest: Manifest = .{
        .identity = sample_identity,
        .entries = &.{
            entryFor("bin/agent", "12345", true),
            entryFor("etc/policy.json", "12345678", false),
        },
    };
    try std.testing.expectEqual(@as(u64, 13), manifest.totalBytes());
}
