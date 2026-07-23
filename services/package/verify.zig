//! Deciding whether a package may be trusted to install, checking its signature,
//! its version against what is installed, and its declared platform, so nothing
//! unsigned, downgraded, or built for another device is ever admitted.
//!
//! A package is code and data about to become part of the system, and admitting it
//! is a decision that has to be made before a single byte is applied, because
//! afterward the trust question is moot. Three checks decide it. The signature must
//! verify against a key the device trusts, because an unsigned or tampered package
//! is code of unknown authorship and installing it is installing anything. The
//! version must be at least what is already installed, because a silent downgrade
//! reintroduces the flaws a newer version fixed and is a known attack path. And the
//! package must declare the platform it was built for and match this device, because
//! a package for another architecture or another product installed here is broken at
//! best and a mismatch that corrupts state at worst. All three are hard gates: any
//! one failing refuses the package, and only a package that passes every check is
//! admitted.
//!
//! This module installs nothing. It decides admit or refuse from a package's
//! signature validity, versions, and platform tag, as a pure function so the same
//! package always meets the same verdict.

const std = @import("std");

/// What the verifier knows about a package and the device.
pub const Package = struct {
    /// Whether the signature verifies against a trusted signing key.
    signature_valid: bool,
    /// The version this package would install.
    version: u32,
    /// The version already installed, or zero for a fresh install.
    installed_version: u32,
    /// The platform tag the package was built for, e.g. an architecture-and-product
    /// identifier.
    platform: []const u8,
    /// This device's platform tag. The package's must match it exactly.
    device_platform: []const u8,
};

/// Why a package was refused.
pub const Refusal = enum {
    /// The signature does not verify: unknown or tampered code.
    invalid_signature,
    /// The version is older than what is installed: a downgrade.
    downgrade,
    /// The package was built for a different platform than this device.
    platform_mismatch,
};

/// The verification verdict.
pub const Verdict = union(enum) {
    admit,
    refuse: Refusal,

    pub fn admitted(verdict: Verdict) bool {
        return verdict == .admit;
    }
};

/// Verifies a package for installation.
///
/// The signature is checked first, because nothing else about an unverified package
/// can be trusted — its declared version and platform are only meaningful once its
/// authorship is. Then the version must not be a downgrade, and the platform must
/// match the device. Every check is a hard gate; a package is admitted only when all
/// three pass.
pub fn verify(package: Package) Verdict {
    if (!package.signature_valid) return .{ .refuse = .invalid_signature };
    if (package.installed_version != 0 and package.version < package.installed_version) {
        return .{ .refuse = .downgrade };
    }
    if (!std.mem.eql(u8, package.platform, package.device_platform)) {
        return .{ .refuse = .platform_mismatch };
    }
    return .admit;
}

fn pkg(valid: bool, version: u32, installed: u32, platform: []const u8) Package {
    return .{
        .signature_valid = valid,
        .version = version,
        .installed_version = installed,
        .platform = platform,
        .device_platform = "arm64-phone",
    };
}

test "a signed, current, matching package is admitted" {
    try std.testing.expect(verify(pkg(true, 3, 2, "arm64-phone")).admitted());
}

test "an unsigned package is refused" {
    try std.testing.expectEqual(Verdict{ .refuse = .invalid_signature }, verify(pkg(false, 3, 2, "arm64-phone")));
}

test "a downgrade is refused" {
    try std.testing.expectEqual(Verdict{ .refuse = .downgrade }, verify(pkg(true, 1, 2, "arm64-phone")));
}

test "the same version and an upgrade are admitted" {
    try std.testing.expect(verify(pkg(true, 2, 2, "arm64-phone")).admitted());
    try std.testing.expect(verify(pkg(true, 5, 2, "arm64-phone")).admitted());
}

test "a fresh install has no downgrade to compare against" {
    try std.testing.expect(verify(pkg(true, 1, 0, "arm64-phone")).admitted());
}

test "a package for another platform is refused" {
    try std.testing.expectEqual(Verdict{ .refuse = .platform_mismatch }, verify(pkg(true, 3, 2, "x86-tablet")));
}

test "the signature is checked before version and platform" {
    // An unsigned, downgraded, mismatched package reports the signature failure — the
    // most fundamental — not the others.
    try std.testing.expectEqual(Verdict{ .refuse = .invalid_signature }, verify(pkg(false, 1, 2, "x86-tablet")));
}

test "any single failed check refuses the package, swept" {
    // The all-gates property: admission requires signature valid AND not a downgrade
    // AND platform match; flipping any one to bad refuses.
    try std.testing.expect(verify(pkg(true, 3, 2, "arm64-phone")).admitted());
    try std.testing.expect(!verify(pkg(false, 3, 2, "arm64-phone")).admitted());
    try std.testing.expect(!verify(pkg(true, 1, 2, "arm64-phone")).admitted());
    try std.testing.expect(!verify(pkg(true, 3, 2, "other-platform")).admitted());
}
