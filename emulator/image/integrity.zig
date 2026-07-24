//! Deciding whether a virtual device may boot an image, so an emulated device runs only a build whose
//! content matches the digest it was authorized under — the same integrity floor a real device holds.
//!
//! The emulator's value is that it is a faithful stand-in: a bug found on a virtual device must be a
//! bug that exists on a real one, and a build proven safe in emulation must be the build that ships. If
//! the emulator would boot any image handed to it, that faithfulness collapses — the thing tested is no
//! longer known to be the thing authorized. So a virtual device boots an image only when the image's
//! measured digest equals the digest the boot was authorized against, exactly. A digest mismatch means
//! the image is not the one that was approved — tampered, truncated, or simply the wrong build — and it
//! is refused rather than booted. This mirrors the real device's verified-boot floor deliberately, so
//! that "it worked in the emulator" carries the same weight as "it worked on hardware": both ran a
//! content-verified image and neither ran anything else.
//!
//! This module boots nothing. It decides whether an image may boot, by comparing its measured digest
//! against the authorized digest, as a pure function.

const std = @import("std");

/// A 256-bit digest identifying an image by its content.
pub const Digest = [32]u8;

/// Whether a measured image digest matches the digest the boot was authorized against.
///
/// The comparison is exact and constant-time over the full digest: the image boots only if every byte
/// matches. Any difference — one flipped bit — is a mismatch and refuses the boot, so the emulator
/// never runs an image other than the one authorized.
pub fn mayBoot(measured: Digest, authorized: Digest) bool {
    return constantTimeEqual(&measured, &authorized);
}

/// Compares two byte slices without short-circuiting, so the decision does not leak where a mismatch
/// occurred through timing.
fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

test "an image whose digest matches the authorization boots" {
    const digest: Digest = [_]u8{0xAB} ** 32;
    try std.testing.expect(mayBoot(digest, digest));
}

test "a one-bit difference refuses the boot" {
    var authorized: Digest = [_]u8{0xAB} ** 32;
    var measured = authorized;
    measured[17] ^= 0x01;
    try std.testing.expect(!mayBoot(measured, authorized));
    _ = &authorized;
}

test "any digest difference refuses the boot, swept" {
    // The verified-image property: the image boots only when its digest equals the authorized one.
    const authorized: Digest = [_]u8{0x00} ** 32;
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        var measured = authorized;
        measured[index] = 0xFF;
        try std.testing.expect(!mayBoot(measured, authorized));
    }
    try std.testing.expect(mayBoot(authorized, authorized));
}
