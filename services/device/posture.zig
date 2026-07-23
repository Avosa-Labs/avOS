//! Deciding which operations a device may perform given how much its integrity can
//! be trusted, so a compromised or unlocked device cannot do the things that assume
//! it is intact.
//!
//! Not every device is in a state to be trusted with everything. One that passed
//! verified boot and attestation is intact; one in developer mode has had its
//! protections deliberately loosened; one that failed attestation may be
//! compromised. High-value operations — releasing a hardware-bound key, authorizing
//! a payment, decrypting the most sensitive data — assume the device is intact, and
//! performing them on a device that is not is how a jailbroken phone drains a wallet
//! or a tampered one exfiltrates secrets. So the operations a device may perform are
//! gated by its posture: the more an operation trusts the device, the better the
//! posture it demands, and a posture that cannot be established denies the sensitive
//! operations while still allowing the ordinary ones a person needs to recover or
//! use the device day to day.
//!
//! This module changes no state. It maps a device posture to the sensitivity of
//! operation it may perform, as a pure function, so one gate governs trust-dependent
//! operations rather than each service guessing.

const std = @import("std");

/// How much the device's integrity can be trusted, best to worst.
pub const Posture = enum(u8) {
    /// Verified boot and attestation both passed: the device is intact.
    attested = 3,
    /// Booted and running, but attestation has not been established this session —
    /// a transient or offline state, trusted for ordinary use but not for the most
    /// sensitive operations.
    unverified = 2,
    /// Developer mode: protections deliberately loosened by the owner. Fine for
    /// development, not for operations that assume an intact device.
    developer = 1,
    /// Attestation failed or tamper was detected: the device may be compromised.
    compromised = 0,

    fn rank(posture: Posture) u8 {
        return @intFromEnum(posture);
    }
};

/// How much an operation trusts the device it runs on.
pub const Sensitivity = enum(u8) {
    /// Ordinary use: run apps, browse, take photos. Allowed on any bootable device
    /// so a person can still use and recover it.
    ordinary = 0,
    /// Elevated: change security settings, enroll a credential. Needs at least an
    /// unverified-but-untampered device.
    elevated = 2,
    /// Critical: release a hardware-bound key, authorize a payment, decrypt the
    /// most sensitive data. Needs a fully attested device.
    critical = 3,

    /// The minimum device posture rank this sensitivity demands.
    fn requiredRank(sensitivity: Sensitivity) u8 {
        return @intFromEnum(sensitivity);
    }
};

/// Whether a device in the given posture may perform an operation of the given
/// sensitivity.
///
/// The device's posture rank must meet or exceed what the operation demands.
/// Ordinary operations demand the least and run on any bootable device, so a person
/// is never locked out of basic use or recovery. Critical operations demand a fully
/// attested device, so a compromised or developer-mode device cannot release a key
/// or authorize a payment. The comparison is monotone: a better posture never
/// permits less than a worse one.
pub fn permits(posture: Posture, sensitivity: Sensitivity) bool {
    return posture.rank() >= sensitivity.requiredRank();
}

test "an attested device may do everything" {
    try std.testing.expect(permits(.attested, .ordinary));
    try std.testing.expect(permits(.attested, .elevated));
    try std.testing.expect(permits(.attested, .critical));
}

test "a compromised device may do only ordinary operations" {
    // Still usable and recoverable, but trusted with nothing sensitive.
    try std.testing.expect(permits(.compromised, .ordinary));
    try std.testing.expect(!permits(.compromised, .elevated));
    try std.testing.expect(!permits(.compromised, .critical));
}

test "developer mode allows elevated but not critical" {
    try std.testing.expect(permits(.developer, .ordinary));
    // Developer rank (1) does not meet elevated (2) or critical (3).
    try std.testing.expect(!permits(.developer, .elevated));
    try std.testing.expect(!permits(.developer, .critical));
}

test "an unverified device allows elevated but not critical" {
    try std.testing.expect(permits(.unverified, .ordinary));
    try std.testing.expect(permits(.unverified, .elevated));
    try std.testing.expect(!permits(.unverified, .critical));
}

test "ordinary operations run on every posture" {
    for ([_]Posture{ .attested, .unverified, .developer, .compromised }) |posture| {
        try std.testing.expect(permits(posture, .ordinary));
    }
}

test "critical operations run only on an attested device" {
    for ([_]Posture{ .unverified, .developer, .compromised }) |posture| {
        try std.testing.expect(!permits(posture, .critical));
    }
    try std.testing.expect(permits(.attested, .critical));
}

test "the gate is monotone in posture, swept" {
    // A better posture never permits less: if a worse posture permits an operation,
    // every better one does too.
    const order = [_]Posture{ .compromised, .developer, .unverified, .attested };
    const sensitivities = [_]Sensitivity{ .ordinary, .elevated, .critical };
    for (order, 0..) |worse, i| {
        for (order[i..]) |better| {
            for (sensitivities) |sensitivity| {
                if (permits(worse, sensitivity)) try std.testing.expect(permits(better, sensitivity));
            }
        }
    }
}
