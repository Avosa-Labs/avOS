//! Deciding whether a backup may be applied, by verifying every item against the
//! manifest before anything is written, so a restore installs the backup that was
//! made or nothing at all.
//!
//! Restore is the dangerous direction. A backup has been sitting on storage the
//! device does not control, and applying it overwrites live state, so a restore
//! that trusts the backup blindly will faithfully install whatever corruption or
//! tampering the backup suffered — and it does so over the very data that could
//! have recovered from the mistake. The discipline that makes restore safe is to
//! verify first and write second: every item's contents are checked against the
//! digest the manifest recorded at backup time, the manifest as a whole is checked
//! against its root, and the backup's format version is checked against what this
//! build understands. Only a backup that passes all three is applied, and it is
//! applied whole; a backup with one bad item is refused rather than half-restored,
//! because a half-restore is its own corruption.
//!
//! This module writes nothing. It decides whether a presented backup is safe to
//! apply, as a pure verification over the manifest and the item bytes offered for
//! it, so the "apply the real backup or nothing" guarantee is made in one place.

const std = @import("std");
const backup = @import("../backup/backup.zig");

/// The newest backup format version this build can apply. A backup written by a
/// newer build may arrange its items in ways this one would misinterpret, so it is
/// refused rather than guessed at.
pub const supported_format_version: u16 = 1;

/// An item offered for restore: the id it claims and the bytes presented for it.
pub const OfferedItem = struct {
    id: u64,
    bytes: []const u8,
};

/// A backup presented for restore: its format version, its manifest, and the item
/// bytes offered to satisfy the manifest.
pub const Presented = struct {
    format_version: u16,
    manifest: []const backup.ManifestEntry,
    /// The manifest root as recorded when the backup was made.
    manifest_root: backup.Digest,
    items: []const OfferedItem,

    fn find(presented: Presented, id: u64) ?OfferedItem {
        for (presented.items) |item| {
            if (item.id == id) return item;
        }
        return null;
    }
};

/// Why a restore was refused.
pub const Refusal = union(enum) {
    /// The backup's format is newer than this build understands.
    incompatible_version: u16,
    /// The manifest does not match its recorded root: the manifest itself was
    /// altered.
    manifest_altered,
    /// A manifest entry has no item offered for it: the backup is incomplete.
    missing_item: u64,
    /// An offered item's contents do not match the digest the manifest recorded:
    /// that item was tampered with or corrupted.
    tampered_item: u64,
};

/// The outcome of a restore decision.
pub const Decision = union(enum) {
    /// Every check passed; the backup is safe to apply whole.
    restore,
    /// The backup is refused and nothing is applied.
    refuse: Refusal,

    pub fn approved(decision: Decision) bool {
        return decision == .restore;
    }
};

/// Decides whether a presented backup may be applied.
///
/// The format version is checked first: a backup this build cannot interpret is
/// refused before its contents are trusted. Then the manifest is checked against
/// its recorded root, so an altered manifest — one with an item added, removed, or
/// repointed — is caught before any digest is trusted. Then every manifest entry
/// must have an offered item whose contents hash to the recorded digest; a missing
/// or mismatching item refuses the whole restore. Only a backup that passes all of
/// this is applied, and because the decision is made before any write, a refusal
/// leaves live state untouched.
pub fn decide(presented: Presented) Decision {
    if (presented.format_version > supported_format_version) {
        return .{ .refuse = .{ .incompatible_version = presented.format_version } };
    }
    if (!std.mem.eql(u8, &backup.manifestRoot(presented.manifest), &presented.manifest_root)) {
        return .{ .refuse = .manifest_altered };
    }
    for (presented.manifest) |entry| {
        const offered = presented.find(entry.id) orelse {
            return .{ .refuse = .{ .missing_item = entry.id } };
        };
        if (!std.mem.eql(u8, &backup.itemDigest(offered.bytes), &entry.digest)) {
            return .{ .refuse = .{ .tampered_item = entry.id } };
        }
    }
    return .restore;
}

fn goodBackup() struct {
    manifest: [2]backup.ManifestEntry,
    items: [2]OfferedItem,
} {
    return .{
        .manifest = .{
            .{ .id = 1, .digest = backup.itemDigest("first") },
            .{ .id = 2, .digest = backup.itemDigest("second") },
        },
        .items = .{
            .{ .id = 1, .bytes = "first" },
            .{ .id = 2, .bytes = "second" },
        },
    };
}

test "a well-formed backup is approved" {
    const b = goodBackup();
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &b.manifest,
        .manifest_root = backup.manifestRoot(&b.manifest),
        .items = &b.items,
    };
    try std.testing.expect(decide(presented).approved());
}

test "a backup from a newer format is refused" {
    const b = goodBackup();
    const presented: Presented = .{
        .format_version = supported_format_version + 1,
        .manifest = &b.manifest,
        .manifest_root = backup.manifestRoot(&b.manifest),
        .items = &b.items,
    };
    try std.testing.expectEqual(
        Decision{ .refuse = .{ .incompatible_version = supported_format_version + 1 } },
        decide(presented),
    );
}

test "an altered manifest is caught against its root" {
    const b = goodBackup();
    // The root was recorded for the real manifest, but a tampered manifest is
    // presented with it.
    var tampered = b.manifest;
    tampered[0].digest = backup.itemDigest("forged");
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &tampered,
        .manifest_root = backup.manifestRoot(&b.manifest), // original root
        .items = &b.items,
    };
    try std.testing.expectEqual(Decision{ .refuse = .manifest_altered }, decide(presented));
}

test "a missing item refuses the whole restore" {
    const b = goodBackup();
    const only_one = [_]OfferedItem{.{ .id = 1, .bytes = "first" }};
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &b.manifest,
        .manifest_root = backup.manifestRoot(&b.manifest),
        .items = &only_one,
    };
    try std.testing.expectEqual(Decision{ .refuse = .{ .missing_item = 2 } }, decide(presented));
}

test "a tampered item is detected and refuses the restore" {
    const b = goodBackup();
    const corrupted = [_]OfferedItem{
        .{ .id = 1, .bytes = "first" },
        .{ .id = 2, .bytes = "second-but-altered" }, // does not match its digest
    };
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &b.manifest,
        .manifest_root = backup.manifestRoot(&b.manifest),
        .items = &corrupted,
    };
    try std.testing.expectEqual(Decision{ .refuse = .{ .tampered_item = 2 } }, decide(presented));
}

test "a backup with one bad item is refused whole, never half-restored" {
    // The all-or-nothing property: the presence of any tampered item yields a
    // refusal, not a partial approval.
    const b = goodBackup();
    const corrupted = [_]OfferedItem{
        .{ .id = 1, .bytes = "altered" },
        .{ .id = 2, .bytes = "second" },
    };
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &b.manifest,
        .manifest_root = backup.manifestRoot(&b.manifest),
        .items = &corrupted,
    };
    try std.testing.expect(!decide(presented).approved());
}

test "an empty backup at a supported version is trivially approved" {
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &.{},
        .manifest_root = backup.manifestRoot(&.{}),
        .items = &.{},
    };
    try std.testing.expect(decide(presented).approved());
}
