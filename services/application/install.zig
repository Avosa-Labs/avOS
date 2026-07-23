//! Deciding whether an application may be installed, so a package that is unsigned,
//! tampered, downgraded, or asking for dangerous authority never lands silently.
//!
//! Installing an application is handing code a place on the device and, through the
//! capabilities it declares, some of the device's authority. Four things decide
//! whether that is safe. The package's signature must verify, because an unsigned or
//! tampered package is code of unknown origin and installing it is installing
//! anything. Its version must not be older than one already installed, because a
//! silent downgrade reintroduces the very flaws a later version fixed. Its source
//! matters: a package from the curated store has been reviewed, while a sideloaded
//! one has not, so the same capability request is weighed differently. And the
//! capabilities themselves are graded — an app that wants only to draw on screen is
//! not an app that wants to read every message — so a dangerous request from an
//! unreviewed source is held for the person rather than granted on install.
//!
//! This module installs nothing. It decides admit, refuse, or hold-for-consent from
//! the package's signature, version, source, and requested capabilities, as a pure
//! function so the same package always meets the same gate.

const std = @import("std");

/// Where a package came from, which sets how much its capability requests are
/// trusted.
pub const Source = enum {
    /// The curated store: reviewed before it was offered.
    store,
    /// Sideloaded: installed directly, with no review. Dangerous capability requests
    /// from here need the person's explicit consent.
    sideload,
};

/// The most sensitive capability a package requests, which sets how carefully the
/// install is weighed.
pub const CapabilityTier = enum {
    /// Self-contained: draw, compute, store its own data. No authority over the
    /// person's data or the device.
    benign,
    /// Reaches the person's data or ordinary device features: files, camera,
    /// location. Reviewed on the store; needs consent when sideloaded.
    sensitive,
    /// Powerful authority: read all messages, control other apps, accessibility
    /// over the whole screen. Always needs consent, even from the store.
    dangerous,
};

/// What the installer knows about a package.
pub const Package = struct {
    /// Whether the signature verifies against a trusted signer.
    signature_valid: bool,
    /// The version being installed.
    version: u32,
    /// The version already installed, or zero if this is a fresh install.
    installed_version: u32,
    source: Source,
    requests: CapabilityTier,
};

/// Why an install was refused outright.
pub const Refusal = enum {
    /// The signature does not verify: unknown or tampered code.
    invalid_signature,
    /// The version is older than what is installed: a downgrade.
    downgrade,
};

/// The install decision.
pub const Decision = union(enum) {
    /// The package may be installed with no further prompt.
    install,
    /// The package may be installed, but its capability requests must be approved by
    /// the person first.
    require_consent,
    /// The install is refused.
    refuse: Refusal,

    pub fn installable(decision: Decision) bool {
        return decision == .install or decision == .require_consent;
    }
};

/// Decides whether a package may be installed.
///
/// The two hard gates come first and refuse outright: a signature that does not
/// verify makes the package unknown code, and a version older than the installed one
/// is a downgrade that reintroduces fixed flaws. Past those, the capability request
/// is weighed against the source: a dangerous request always needs consent whatever
/// the source, a sensitive request needs consent when sideloaded but not from the
/// reviewed store, and a benign request installs directly. Nothing dangerous is ever
/// granted silently.
pub fn decide(package: Package) Decision {
    if (!package.signature_valid) return .{ .refuse = .invalid_signature };
    if (package.installed_version != 0 and package.version < package.installed_version) {
        return .{ .refuse = .downgrade };
    }

    switch (package.requests) {
        .dangerous => return .require_consent,
        .sensitive => return if (package.source == .sideload) .require_consent else .install,
        .benign => return .install,
    }
}

fn pkg(valid: bool, version: u32, installed: u32, source: Source, requests: CapabilityTier) Package {
    return .{
        .signature_valid = valid,
        .version = version,
        .installed_version = installed,
        .source = source,
        .requests = requests,
    };
}

test "a signed benign store app installs directly" {
    try std.testing.expectEqual(Decision.install, decide(pkg(true, 2, 0, .store, .benign)));
}

test "an unsigned package is refused whatever else it is" {
    try std.testing.expectEqual(Decision{ .refuse = .invalid_signature }, decide(pkg(false, 2, 0, .store, .benign)));
}

test "a downgrade is refused" {
    // Installed version 5, trying to install 4.
    try std.testing.expectEqual(Decision{ .refuse = .downgrade }, decide(pkg(true, 4, 5, .store, .benign)));
}

test "the same version reinstalls, and an upgrade installs" {
    try std.testing.expect(decide(pkg(true, 5, 5, .store, .benign)).installable());
    try std.testing.expect(decide(pkg(true, 6, 5, .store, .benign)).installable());
}

test "a dangerous capability request always needs consent, even from the store" {
    try std.testing.expectEqual(Decision.require_consent, decide(pkg(true, 1, 0, .store, .dangerous)));
    try std.testing.expectEqual(Decision.require_consent, decide(pkg(true, 1, 0, .sideload, .dangerous)));
}

test "a sensitive request needs consent when sideloaded but not from the store" {
    try std.testing.expectEqual(Decision.install, decide(pkg(true, 1, 0, .store, .sensitive)));
    try std.testing.expectEqual(Decision.require_consent, decide(pkg(true, 1, 0, .sideload, .sensitive)));
}

test "the hard gates precede the capability weighing" {
    // An unsigned dangerous sideload reports the signature failure, the more
    // fundamental problem, not the consent requirement.
    try std.testing.expectEqual(Decision{ .refuse = .invalid_signature }, decide(pkg(false, 1, 0, .sideload, .dangerous)));
    // A signed downgrade is refused before its capabilities are considered.
    try std.testing.expectEqual(Decision{ .refuse = .downgrade }, decide(pkg(true, 1, 3, .sideload, .dangerous)));
}

test "an unsigned or downgraded package never installs, swept" {
    // The hard-gate property: whatever the source and capabilities, an invalid
    // signature or a downgrade is never installable.
    for ([_]Source{ .store, .sideload }) |source| {
        for ([_]CapabilityTier{ .benign, .sensitive, .dangerous }) |tier| {
            try std.testing.expect(!decide(pkg(false, 2, 0, source, tier)).installable());
            try std.testing.expect(!decide(pkg(true, 2, 5, source, tier)).installable());
        }
    }
}

test "nothing dangerous ever installs without consent, swept" {
    // A dangerous request, whenever it is installable at all, is always gated by
    // consent — never a bare install.
    for ([_]Source{ .store, .sideload }) |source| {
        const decision = decide(pkg(true, 2, 0, source, .dangerous));
        try std.testing.expectEqual(Decision.require_consent, decision);
    }
}
