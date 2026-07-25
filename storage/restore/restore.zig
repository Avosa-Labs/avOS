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

/// The oldest backup format this build still accepts. A backup older than this is
/// refused rather than applied, so a stale backup cannot force the device back onto
/// a format whose weaknesses a later version fixed. Raise this when an old format is
/// retired.
pub const minimum_format_version: u16 = 1;

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
    /// The authenticator the making device computed over the root under its key.
    /// The root is trusted only if this re-computes under the device's key.
    authenticator: backup.Authenticator,
    items: []const OfferedItem,

    fn find(presented: Presented, id: u64) ?OfferedItem {
        for (presented.items) |item| {
            if (item.id == id) return item;
        }
        return null;
    }
};

/// What the device brings to a restore that the backup cannot supply for itself:
/// the key its root was authenticated under. Held on the device, never in the
/// backup, so a backup on foreign storage cannot be re-rooted to forged contents.
pub const Trust = struct {
    manifest_key: []const u8,
};

/// Why a restore was refused.
pub const Refusal = union(enum) {
    /// The backup's format is newer than this build understands.
    incompatible_version: u16,
    /// The backup's format is older than this build still accepts: applying it
    /// would downgrade the device to a retired format.
    downgraded: u16,
    /// The manifest root is not authentic under this device's key: the backup was
    /// not made by this device, or its root was forged.
    unauthenticated,
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
/// The format version is checked first: a backup newer than this build can
/// interpret, or older than it still accepts, is refused before its contents are
/// trusted. Then the manifest root is authenticated against the device's key — this
/// is what ties the backup to this device, and it comes before the root is used for
/// anything, because a forged manifest carries a self-consistent forged root that
/// the manifest-altered check alone would wave through. Then the manifest is checked
/// against that now-trusted root, so an altered manifest — one with an item added,
/// removed, or repointed — is caught. Then every manifest entry must have an offered
/// item whose contents hash to the recorded digest; a missing or mismatching item
/// refuses the whole restore. Only a backup that passes all of this is applied, and
/// because the decision is made before any write, a refusal leaves live state
/// untouched.
pub fn decide(presented: Presented, trust: Trust) Decision {
    if (presented.format_version > supported_format_version) {
        return .{ .refuse = .{ .incompatible_version = presented.format_version } };
    }
    if (presented.format_version < minimum_format_version) {
        return .{ .refuse = .{ .downgraded = presented.format_version } };
    }
    if (!backup.rootIsAuthentic(presented.manifest_root, trust.manifest_key, presented.authenticator)) {
        return .{ .refuse = .unauthenticated };
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

/// The key a test device authenticates its backup roots under. Never travels in a
/// backup; the restore side already holds it.
const device_key = "a device-held manifest key, never in the backup";

fn deviceTrust() Trust {
    return .{ .manifest_key = device_key };
}

/// Builds a Presented over a manifest, authenticating the recorded root under the
/// device key as a real making device would.
fn presentedFor(
    manifest: []const backup.ManifestEntry,
    items: []const OfferedItem,
) Presented {
    const root = backup.manifestRoot(manifest);
    return .{
        .format_version = supported_format_version,
        .manifest = manifest,
        .manifest_root = root,
        .authenticator = backup.authenticateRoot(root, device_key),
        .items = items,
    };
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
    try std.testing.expect(decide(presentedFor(&b.manifest, &b.items), deviceTrust()).approved());
}

test "a backup from a newer format is refused" {
    const b = goodBackup();
    var presented = presentedFor(&b.manifest, &b.items);
    presented.format_version = supported_format_version + 1;
    try std.testing.expectEqual(
        Decision{ .refuse = .{ .incompatible_version = supported_format_version + 1 } },
        decide(presented, deviceTrust()),
    );
}

test "a backup older than this build accepts is refused as a downgrade" {
    const b = goodBackup();
    var presented = presentedFor(&b.manifest, &b.items);
    presented.format_version = minimum_format_version - 1;
    try std.testing.expectEqual(
        Decision{ .refuse = .{ .downgraded = minimum_format_version - 1 } },
        decide(presented, deviceTrust()),
    );
}

test "a backup not authenticated by this device is refused" {
    const b = goodBackup();
    const presented = presentedFor(&b.manifest, &b.items);
    // The device holds a different key than the one the backup was authenticated
    // under, so its root is not trusted.
    try std.testing.expectEqual(
        Decision{ .refuse = .unauthenticated },
        decide(presented, .{ .manifest_key = "some other device's key" }),
    );
}

test "a forged manifest with a self-consistent root is refused as unauthenticated" {
    // The core attack: an attacker rewrites the whole manifest and recomputes the
    // root to match, so the manifest-altered check would pass. Only the missing
    // authenticator stops it — the attacker cannot MAC the forged root.
    const forged = [_]backup.ManifestEntry{
        .{ .id = 1, .digest = backup.itemDigest("payload the attacker chose") },
    };
    const forged_items = [_]OfferedItem{
        .{ .id = 1, .bytes = "payload the attacker chose" },
    };
    const forged_root = backup.manifestRoot(&forged);
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &forged,
        .manifest_root = forged_root, // self-consistent: matches the forged manifest
        .authenticator = backup.authenticateRoot(forged_root, "the attacker's own key"),
        .items = &forged_items,
    };
    try std.testing.expectEqual(Decision{ .refuse = .unauthenticated }, decide(presented, deviceTrust()));
}

test "an altered manifest is caught against its root" {
    const b = goodBackup();
    // The root was recorded and authenticated for the real manifest, but a tampered
    // manifest is presented with it. Authentication passes on the real root; the
    // manifest-altered check catches the swap.
    var tampered = b.manifest;
    tampered[0].digest = backup.itemDigest("forged");
    const made_root = backup.manifestRoot(&b.manifest);
    const presented: Presented = .{
        .format_version = supported_format_version,
        .manifest = &tampered,
        .manifest_root = made_root,
        .authenticator = backup.authenticateRoot(made_root, device_key),
        .items = &b.items,
    };
    try std.testing.expectEqual(Decision{ .refuse = .manifest_altered }, decide(presented, deviceTrust()));
}

test "a missing item refuses the whole restore" {
    const b = goodBackup();
    const only_one = [_]OfferedItem{.{ .id = 1, .bytes = "first" }};
    try std.testing.expectEqual(
        Decision{ .refuse = .{ .missing_item = 2 } },
        decide(presentedFor(&b.manifest, &only_one), deviceTrust()),
    );
}

test "a tampered item is detected and refuses the restore" {
    const b = goodBackup();
    const corrupted = [_]OfferedItem{
        .{ .id = 1, .bytes = "first" },
        .{ .id = 2, .bytes = "second-but-altered" }, // does not match its digest
    };
    try std.testing.expectEqual(
        Decision{ .refuse = .{ .tampered_item = 2 } },
        decide(presentedFor(&b.manifest, &corrupted), deviceTrust()),
    );
}

test "a backup with one bad item is refused whole, never half-restored" {
    // The all-or-nothing property: the presence of any tampered item yields a
    // refusal, not a partial approval.
    const b = goodBackup();
    const corrupted = [_]OfferedItem{
        .{ .id = 1, .bytes = "altered" },
        .{ .id = 2, .bytes = "second" },
    };
    try std.testing.expect(!decide(presentedFor(&b.manifest, &corrupted), deviceTrust()).approved());
}

test "an empty backup at a supported version is trivially approved" {
    try std.testing.expect(decide(presentedFor(&.{}, &.{}), deviceTrust()).approved());
}
