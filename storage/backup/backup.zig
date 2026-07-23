//! Deciding what may be copied into a backup and binding the copy to a digest, so
//! a backup neither leaks a device-bound secret nor can be tampered with unnoticed.
//!
//! A backup is a copy of state that leaves the device — to a companion, to the
//! cloud, to a cable — and that departure raises two questions the copy itself
//! cannot answer later. First, some state must not leave in a form anyone but the
//! person can read: a key sealed to this device's hardware, a token that is only
//! meaningful here, belongs in a backup only if the backup is end-to-end encrypted,
//! and copying it into a plaintext backup is a leak dressed as a convenience.
//! Second, a backup is only useful if a restore can trust it, and a copy sitting on
//! foreign storage can be corrupted or altered; so every item is bound to a digest
//! at backup time and the whole set is bound to a root, and a restore that finds a
//! mismatch knows the backup was damaged rather than applying wrong data.
//!
//! This module writes no backup. It decides whether an item is eligible given the
//! backup's protection, computes the per-item digest and the manifest root that
//! bind the copy to its contents, as pure functions the restore side checks
//! against.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The digest that binds an item, or the whole manifest, to its contents.
pub const Digest = [Sha256.digest_length]u8;

/// How sensitive an item is, which decides whether it may enter a plaintext
/// backup.
pub const Sensitivity = enum {
    /// Ordinary state: documents, settings, app data. May be backed up either way.
    ordinary,
    /// A secret bound to this device or person that must never leave in the clear:
    /// a sealed key, a device-scoped token. Only ever backed up under end-to-end
    /// encryption.
    device_bound_secret,
};

/// How a backup protects its contents once it leaves the device.
pub const Protection = enum {
    /// Readable by whoever holds the backup. A device-bound secret must not enter
    /// one of these.
    plaintext,
    /// Encrypted so only the person can read it, wherever it is stored. A
    /// device-bound secret may enter one of these.
    end_to_end_encrypted,

    fn protectsSecrets(protection: Protection) bool {
        return protection == .end_to_end_encrypted;
    }
};

/// An item considered for a backup.
pub const Item = struct {
    id: u64,
    bytes: []const u8,
    sensitivity: Sensitivity = .ordinary,
};

/// Whether an item may be included in a backup with the given protection.
///
/// Ordinary state is always eligible. A device-bound secret is eligible only when
/// the backup is end-to-end encrypted, so a plaintext backup can never carry a
/// secret off the device in a readable form. This is the leak-prevention gate, and
/// it fails closed: anything sensitive is excluded unless the protection is proven
/// sufficient.
pub fn includeInBackup(item: Item, protection: Protection) bool {
    return switch (item.sensitivity) {
        .ordinary => true,
        .device_bound_secret => protection.protectsSecrets(),
    };
}

/// Computes the digest binding an item's contents.
pub fn itemDigest(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// One line of a manifest: an item's id and the digest of its contents.
pub const ManifestEntry = struct {
    id: u64,
    digest: Digest,
};

/// Builds a manifest entry for an item.
pub fn entryOf(item: Item) ManifestEntry {
    return .{ .id = item.id, .digest = itemDigest(item.bytes) };
}

/// Computes the manifest root over a set of entries.
///
/// The root hashes each entry's id and digest in order, so it covers both what is
/// in the backup and which item each digest belongs to — a swapped pair of items
/// changes the root even if the two digests are individually unchanged. A restore
/// checks this root to confirm the manifest as a whole was not altered.
pub fn manifestRoot(entries: []const ManifestEntry) Digest {
    var hasher = Sha256.init(.{});
    for (entries) |entry| {
        var id_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &id_bytes, entry.id, .little);
        hasher.update(&id_bytes);
        hasher.update(&entry.digest);
    }
    var root: Digest = undefined;
    hasher.final(&root);
    return root;
}

test "ordinary state is eligible under either protection" {
    const item: Item = .{ .id = 1, .bytes = "a document", .sensitivity = .ordinary };
    try std.testing.expect(includeInBackup(item, .plaintext));
    try std.testing.expect(includeInBackup(item, .end_to_end_encrypted));
}

test "a device-bound secret is excluded from a plaintext backup" {
    const secret: Item = .{ .id = 2, .bytes = "a sealed key", .sensitivity = .device_bound_secret };
    try std.testing.expect(!includeInBackup(secret, .plaintext));
    try std.testing.expect(includeInBackup(secret, .end_to_end_encrypted));
}

test "an item digest is deterministic and content-sensitive" {
    try std.testing.expectEqual(itemDigest("data"), itemDigest("data"));
    try std.testing.expect(!std.mem.eql(u8, &itemDigest("data"), &itemDigest("dat0")));
}

test "the manifest root covers every entry" {
    const items = [_]Item{
        .{ .id = 1, .bytes = "one" },
        .{ .id = 2, .bytes = "two" },
    };
    var entries: [2]ManifestEntry = undefined;
    for (items, 0..) |item, i| entries[i] = entryOf(item);
    const root = manifestRoot(&entries);

    // Changing any item's contents changes the root.
    var changed = entries;
    changed[0].digest = itemDigest("ONE");
    try std.testing.expect(!std.mem.eql(u8, &root, &manifestRoot(&changed)));
}

test "the manifest root binds a digest to its item, catching a swap" {
    // Two items with the same pair of digests but swapped ids must produce a
    // different root, so an attacker cannot move a good digest onto the wrong item.
    const a: ManifestEntry = .{ .id = 1, .digest = itemDigest("alpha") };
    const b: ManifestEntry = .{ .id = 2, .digest = itemDigest("beta") };
    const original = [_]ManifestEntry{ a, b };
    const swapped = [_]ManifestEntry{
        .{ .id = 1, .digest = b.digest },
        .{ .id = 2, .digest = a.digest },
    };
    try std.testing.expect(!std.mem.eql(u8, &manifestRoot(&original), &manifestRoot(&swapped)));
}

test "no device-bound secret is ever eligible for a plaintext backup, swept" {
    // The leak property: whatever the item, a plaintext backup admits it only if it
    // is not a device-bound secret.
    for ([_]Sensitivity{ .ordinary, .device_bound_secret }) |sensitivity| {
        const item: Item = .{ .id = 9, .bytes = "x", .sensitivity = sensitivity };
        if (includeInBackup(item, .plaintext)) {
            try std.testing.expectEqual(Sensitivity.ordinary, sensitivity);
        }
    }
}

test "an empty manifest has a stable root" {
    try std.testing.expectEqual(manifestRoot(&.{}), manifestRoot(&.{}));
}
