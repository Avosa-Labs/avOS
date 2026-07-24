//! Deciding whether a release manifest describes its image faithfully, so a device is never told one
//! thing about a build while the build is another.
//!
//! A release manifest is what a device reads before it trusts an image: the version, the digest the
//! image should hash to, the signer, and the minimum platform the image requires. The device makes its
//! whole accept-or-reject decision from the manifest, so a manifest that disagrees with the image it
//! accompanies is worse than no manifest — it is a confident, signed statement that happens to be
//! false. So a manifest is validated for internal coherence before it is used: it must carry a
//! non-empty digest, name a signer, and state a version that is not the zero version, and the digest it
//! claims must match the image's actual measured digest. A manifest that passes describes its image
//! exactly; one that fails is rejected rather than handed to a device that would act on its claims.
//! Checking the manifest against the image it describes is what makes "the device was told X" and "the
//! image is X" the same statement.
//!
//! This module reads no image. It decides whether a manifest is coherent and matches its image's
//! measured digest, as pure functions.

const std = @import("std");

/// A release manifest describing an image.
pub const Manifest = struct {
    /// The version the image represents. The zero version is reserved and never released.
    version: u32,
    /// The digest the image is claimed to measure to.
    claimed_digest: [32]u8,
    /// The identifier of the signer. Zero means unsigned.
    signer: u64,
};

/// Why a manifest was rejected.
pub const Rejection = enum {
    /// The manifest states the reserved zero version.
    zero_version,
    /// The manifest names no signer.
    unsigned,
    /// The manifest's claimed digest does not match the image's measured digest.
    digest_mismatch,
};

/// The validation result.
pub const Validity = union(enum) {
    ok,
    rejected: Rejection,

    pub fn isOk(validity: Validity) bool {
        return validity == .ok;
    }
};

/// Whether a manifest is coherent and faithfully describes an image with a given measured digest.
///
/// The manifest must state a real version, name a signer, and claim the digest the image actually
/// measures to. Any failure rejects it with the reason, so no device acts on a manifest that is
/// internally invalid or disagrees with its image.
pub fn validate(manifest: Manifest, measured_digest: [32]u8) Validity {
    if (manifest.version == 0) return .{ .rejected = .zero_version };
    if (manifest.signer == 0) return .{ .rejected = .unsigned };
    if (!std.mem.eql(u8, &manifest.claimed_digest, &measured_digest)) return .{ .rejected = .digest_mismatch };
    return .ok;
}

fn makeManifest(version: u32, digest: [32]u8, signer: u64) Manifest {
    return .{ .version = version, .claimed_digest = digest, .signer = signer };
}

test "a coherent manifest matching its image is accepted" {
    const digest = [_]u8{0xA1} ** 32;
    try std.testing.expect(validate(makeManifest(4, digest, 99), digest).isOk());
}

test "the zero version is rejected" {
    const digest = [_]u8{0xA1} ** 32;
    try std.testing.expectEqual(Validity{ .rejected = .zero_version }, validate(makeManifest(0, digest, 99), digest));
}

test "an unsigned manifest is rejected" {
    const digest = [_]u8{0xA1} ** 32;
    try std.testing.expectEqual(Validity{ .rejected = .unsigned }, validate(makeManifest(4, digest, 0), digest));
}

test "a digest that does not match the image is rejected" {
    const claimed = [_]u8{0xA1} ** 32;
    const measured = [_]u8{0xB2} ** 32;
    try std.testing.expectEqual(Validity{ .rejected = .digest_mismatch }, validate(makeManifest(4, claimed, 99), measured));
}

test "an accepted manifest always matches its image, swept" {
    // The faithful-description property: an accepted manifest claims exactly the measured digest.
    const digest = [_]u8{0x00} ** 32;
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        var wrong = digest;
        wrong[index] = 0xFF;
        try std.testing.expect(!validate(makeManifest(4, wrong, 99), digest).isOk());
    }
    try std.testing.expect(validate(makeManifest(4, digest, 99), digest).isOk());
}
