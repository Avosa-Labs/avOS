//! Deciding whether an emulator bundle is safe to distribute to developers, so a virtual device image
//! handed out for development is clearly marked non-production and never carries release signing keys.
//!
//! The emulator bundle is what a developer downloads to run a virtual device: an image, a device
//! profile, and the tooling to boot it. It is deliberately not a production artifact, and treating it
//! like one is dangerous in two directions. It must be marked as a development build so nothing — no
//! device, no store, no person — mistakes an emulator image for a shippable release. And it must never
//! contain a production signing key: a bundle distributed widely to developers is exactly the wrong
//! place for the key that authorizes real device images, and including one would leak the platform's
//! most sensitive secret to everyone who downloads the emulator. So a bundle is publishable only when it
//! is flagged development-only and carries no production key material. A bundle that is either unflagged
//! or key-bearing is refused before distribution. Keeping the emulator bundle plainly non-production and
//! key-free is what lets it be shared freely without becoming a supply-chain hole.
//!
//! This module distributes nothing. It decides whether an emulator bundle may be published, from its
//! development flag and whether it carries production key material, as a pure function.

const std = @import("std");

/// An emulator bundle presented for distribution.
pub const Bundle = struct {
    /// Whether the bundle is flagged as a development-only artifact.
    development_flagged: bool,
    /// Whether the bundle contains production signing key material.
    contains_production_key: bool,
};

/// Why a bundle was refused.
pub const Refusal = enum {
    /// The bundle is not flagged development-only and could be mistaken for a release.
    not_development_flagged,
    /// The bundle carries production signing key material.
    carries_production_key,
};

/// The publish decision.
pub const Decision = union(enum) {
    publish,
    refuse: Refusal,

    pub fn publishes(decision: Decision) bool {
        return decision == .publish;
    }
};

/// Decides whether an emulator bundle may be published to developers.
///
/// The bundle must be flagged development-only, and it must carry no production key. The key check is
/// decisive: a bundle carrying production key material is refused even if flagged, because the leak is
/// the graver failure. Only a flagged, key-free bundle publishes.
pub fn decide(bundle: Bundle) Decision {
    if (bundle.contains_production_key) return .{ .refuse = .carries_production_key };
    if (!bundle.development_flagged) return .{ .refuse = .not_development_flagged };
    return .publish;
}

fn makeBundle(flagged: bool, has_key: bool) Bundle {
    return .{ .development_flagged = flagged, .contains_production_key = has_key };
}

test "a flagged, key-free bundle publishes" {
    try std.testing.expect(decide(makeBundle(true, false)).publishes());
}

test "a bundle carrying a production key is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .carries_production_key }, decide(makeBundle(true, true)));
}

test "an unflagged bundle is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .not_development_flagged }, decide(makeBundle(false, false)));
}

test "no published bundle ever carries a production key, swept" {
    // The no-key-leak property: a published bundle is flagged and key-free.
    for ([_]bool{ false, true }) |flagged| {
        for ([_]bool{ false, true }) |has_key| {
            if (decide(makeBundle(flagged, has_key)).publishes()) {
                try std.testing.expect(flagged and !has_key);
            }
        }
    }
}
