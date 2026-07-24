//! Deciding whether an app build is signed well enough to distribute, so only a registered
//! developer's reviewed build ever reaches a device through the store.
//!
//! A store distributes code, and the signature chain is what lets a device trust that the code
//! is what the store approved. Two signatures must both hold. The developer signs the build with
//! a key registered to their account, which proves the build came from them and not an impostor;
//! a build signed by an unregistered or revoked key is rejected, because its origin cannot be
//! established. And the store countersigns the exact build it reviewed and approved, which
//! proves this build — not a swapped one — is the one that passed review; a build whose store
//! countersignature is missing or does not match is rejected, because it may be a malicious
//! build wearing an approved developer's name. Both together mean a distributed build is
//! provably from a known developer and provably the reviewed artifact, which is the guarantee a
//! person relies on when they install from the store rather than the open internet.
//!
//! This module verifies no cryptography itself. It decides whether a build's signing state
//! permits distribution, from the developer and store signatures, as a pure function.

const std = @import("std");

/// The signing state of a build presented for distribution.
pub const Signing = struct {
    /// Whether the developer signature verifies against a currently-registered developer key.
    developer_signature_valid: bool,
    /// Whether the developer's key is registered and not revoked.
    developer_registered: bool,
    /// Whether the store countersignature matches this exact reviewed build.
    store_countersigned: bool,
};

/// Why a build was rejected for distribution.
pub const Rejection = enum {
    /// The developer signature does not verify.
    invalid_developer_signature,
    /// The developer's key is unregistered or revoked.
    developer_not_registered,
    /// The store countersignature is missing or does not match this build.
    not_countersigned,
};

/// The distribution-signing decision.
pub const Decision = union(enum) {
    distribute,
    reject: Rejection,

    pub fn distributes(decision: Decision) bool {
        return decision == .distribute;
    }
};

/// Decides whether a build's signing permits distribution.
///
/// The developer signature must verify and the developer's key must be registered and not
/// revoked, establishing the build's origin. The store must have countersigned this exact
/// reviewed build, establishing that it is the approved artifact. All three are required; a
/// build missing any is rejected, so a distributed build is always both from a known developer
/// and the reviewed one.
pub fn decide(signing: Signing) Decision {
    if (!signing.developer_signature_valid) return .{ .reject = .invalid_developer_signature };
    if (!signing.developer_registered) return .{ .reject = .developer_not_registered };
    if (!signing.store_countersigned) return .{ .reject = .not_countersigned };
    return .distribute;
}

fn makeSigning(dev_valid: bool, dev_registered: bool, countersigned: bool) Signing {
    return .{
        .developer_signature_valid = dev_valid,
        .developer_registered = dev_registered,
        .store_countersigned = countersigned,
    };
}

test "a fully-signed build distributes" {
    try std.testing.expect(decide(makeSigning(true, true, true)).distributes());
}

test "an invalid developer signature is rejected" {
    try std.testing.expectEqual(Decision{ .reject = .invalid_developer_signature }, decide(makeSigning(false, true, true)));
}

test "an unregistered developer is rejected" {
    try std.testing.expectEqual(Decision{ .reject = .developer_not_registered }, decide(makeSigning(true, false, true)));
}

test "a build without the store countersignature is rejected" {
    try std.testing.expectEqual(Decision{ .reject = .not_countersigned }, decide(makeSigning(true, true, false)));
}

test "no build distributes without both signatures, swept" {
    // The provenance property: a distributed build is always developer-signed, registered, and
    // store-countersigned.
    for ([_]bool{ false, true }) |dev| {
        for ([_]bool{ false, true }) |registered| {
            for ([_]bool{ false, true }) |counter| {
                if (decide(makeSigning(dev, registered, counter)).distributes()) {
                    try std.testing.expect(dev and registered and counter);
                }
            }
        }
    }
}
