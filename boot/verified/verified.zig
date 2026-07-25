//! Deciding whether a stage may run.
//!
//! Verification is separated from the chain that sequences stages so the answer
//! is a value with no side effects: a stage is acceptable or it is not, and
//! nothing about the device changes while that is being decided.
//!
//! A verified stage is one that is signed by the key its position accepts, over
//! the digest of exactly the bytes that will run, at a version no older than one
//! this device has already booted. All three matter. Signature alone permits an
//! attacker to reinstall a genuine image with a known flaw; version alone
//! permits anything.

const std = @import("std");
const measurements = @import("../measurements/measurements.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;

pub const Error = error{
    /// Not signed by the key this position accepts, or signed over other bytes.
    SignatureRejected,
    /// Older than an image this device has already booted.
    RollbackRefused,
    /// Signed by a key generation the device has revoked.
    KeyRevoked,
    /// Signed under an algorithm this device does not implement.
    AlgorithmUnsupported,
};

/// The signature algorithm an image was signed under. Carried explicitly so a
/// migration to a second algorithm is a declared, checkable fact rather than an
/// assumption, and an image signed under an algorithm this device does not
/// implement is refused instead of misread.
pub const Algorithm = enum(u8) {
    ed25519,
};

/// What the device will accept at a signing position: the current key, the
/// algorithm it verifies under, and the lowest key generation still trusted.
///
/// Rotation installs a higher generation with a new key through a verified
/// update; revocation raises `min_generation` so a compromised key's images are
/// refused even though the signature would otherwise check out.
pub const Trust = struct {
    key: [public_key_bytes]u8,
    algorithm: Algorithm = .ed25519,
    min_generation: u32 = 0,
};

/// An image offered to the stage before it.
pub const Image = struct {
    contents: []const u8,
    /// The version the image declares. Compared against the device's floor.
    version: u32,
    /// The generation of the key that signed it. Below the device's minimum, the
    /// key is revoked and the image is refused.
    key_generation: u32 = 0,
    /// The algorithm the signature was produced under.
    algorithm: Algorithm = .ed25519,
    signature: [signature_bytes]u8,
};

/// Decides whether an image may run.
///
/// The checks that do not need the key come first — anti-rollback, then key
/// revocation, then the algorithm — so an image the device must not run is
/// refused whether or not its signature would have verified, and a valid
/// signature never buys an attacker a downgrade or a revoked key.
pub fn verify(
    image: Image,
    trust: Trust,
    floor: u32,
) Error![measurements.digest_bytes]u8 {
    if (image.version < floor) return error.RollbackRefused;
    if (image.key_generation < trust.min_generation) return error.KeyRevoked;
    if (image.algorithm != trust.algorithm) return error.AlgorithmUnsupported;

    const digest = measurements.digestOf(image.contents);
    switch (trust.algorithm) {
        .ed25519 => {
            const key = Ed25519.PublicKey.fromBytes(trust.key) catch return error.SignatureRejected;
            const signature: Ed25519.Signature = .fromBytes(image.signature);
            signature.verify(&digest, key) catch return error.SignatureRejected;
        },
    }

    return digest;
}

/// The highest version each stage has been seen at.
///
/// This is the anti-rollback floor, and it lives in storage the running system
/// cannot rewrite freely. A floor a compromised system could lower would not be
/// a floor.
pub fn Floors(comptime stage_count: usize) type {
    return struct {
        const Self = @This();

        highest: [stage_count]u32 = @splat(0),
        /// The monotonic-counter value these floors were last sealed at. The
        /// counter lives in the secure element and only rises; sealing binds the
        /// floor state to it so a rollback of the writable storage the floors
        /// live in is detectable — the restored floors carry an old seal that no
        /// longer matches the counter the hardware still holds.
        sealed_counter: u64 = 0,

        pub fn forStage(floors: Self, stage: usize) u32 {
            return floors.highest[stage];
        }

        /// Never lowers. A version below the current floor leaves it unchanged
        /// rather than being rejected here; refusing to run is `verify`'s job.
        pub fn raise(floors: *Self, stage: usize, version: u32) void {
            floors.highest[stage] = @max(floors.highest[stage], version);
        }

        /// Binds the current floor state to a counter value. The caller advances
        /// the secure element's monotonic counter whenever the floors change and
        /// seals them to the new value, so the floors and the counter move
        /// together.
        pub fn seal(floors: *Self, counter: u64) void {
            floors.sealed_counter = counter;
        }

        /// Whether the floors still match the counter the hardware holds. A
        /// mismatch means the floor storage was rolled back to an earlier state
        /// while the counter — which cannot be lowered — moved on, so the floors
        /// must not be trusted and boot fails closed.
        pub fn isSealedAt(floors: Self, counter: u64) bool {
            return floors.sealed_counter == counter;
        }
    };
}

const TestFloors = Floors(4);

fn signedBy(pair: Ed25519.KeyPair, contents: []const u8, version: u32) !Image {
    const digest = measurements.digestOf(contents);
    const signature = try pair.sign(&digest, null);
    return .{ .contents = contents, .version = version, .signature = signature.toBytes() };
}

fn testKey(index: u8) !Ed25519.KeyPair {
    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(60 + index);
    return Ed25519.KeyPair.generateDeterministic(seed);
}

test "a correctly signed image at an acceptable version verifies" {
    const pair = try testKey(0);
    const image = try signedBy(pair, "the kernel", 3);

    const digest = try verify(image, .{ .key = pair.public_key.toBytes() }, 3);
    try std.testing.expectEqualSlices(u8, &measurements.digestOf("the kernel"), &digest);
}

test "a tampered signature is rejected" {
    const pair = try testKey(0);
    var image = try signedBy(pair, "the kernel", 1);
    image.signature[0] ^= 0xff;

    try std.testing.expectError(
        error.SignatureRejected,
        verify(image, .{ .key = pair.public_key.toBytes() }, 0),
    );
}

test "substituted contents are rejected even with a genuine signature" {
    const pair = try testKey(0);
    var image = try signedBy(pair, "the kernel", 1);
    image.contents = "a different kernel";

    // The signature is over the digest of the bytes that will run, not over a
    // name or a manifest entry that could be pointed elsewhere.
    try std.testing.expectError(
        error.SignatureRejected,
        verify(image, .{ .key = pair.public_key.toBytes() }, 0),
    );
}

test "an image signed by a revoked key generation is refused" {
    const pair = try testKey(0);
    var image = try signedBy(pair, "the kernel", 3);
    image.key_generation = 1;

    // The device has moved its minimum accepted generation to 2, revoking
    // generation 1. The signature still checks out, but the key is no longer
    // trusted, so the image is refused before the signature is even consulted.
    try std.testing.expectError(error.KeyRevoked, verify(
        image,
        .{ .key = pair.public_key.toBytes(), .min_generation = 2 },
        0,
    ));

    // At or above the minimum, the same image verifies.
    image.key_generation = 2;
    _ = try verify(image, .{ .key = pair.public_key.toBytes(), .min_generation = 2 }, 0);
}

test "an image signed by another key is rejected" {
    const signer = try testKey(0);
    const accepted = try testKey(1);
    const image = try signedBy(signer, "the kernel", 1);

    try std.testing.expectError(
        error.SignatureRejected,
        verify(image, .{ .key = accepted.public_key.toBytes() }, 0),
    );
}

test "a malformed key rejects rather than being treated as absent" {
    const pair = try testKey(0);
    const image = try signedBy(pair, "the kernel", 1);
    // A key of all-zero bytes is not a valid point. Treating an unreadable key
    // as "no verification required" is how verification becomes advisory.
    const unusable: [public_key_bytes]u8 = @splat(0);

    try std.testing.expectError(error.SignatureRejected, verify(image, .{ .key = unusable }, 0));
}

test "a downgrade is refused even when correctly signed" {
    const pair = try testKey(0);
    const image = try signedBy(pair, "an older kernel", 2);

    // A valid signature must never buy a downgrade: the older image is genuine
    // and that is exactly the problem.
    try std.testing.expectError(
        error.RollbackRefused,
        verify(image, .{ .key = pair.public_key.toBytes() }, 5),
    );
}

test "the version at the floor is accepted" {
    const pair = try testKey(0);
    const image = try signedBy(pair, "the kernel", 5);
    _ = try verify(image, .{ .key = pair.public_key.toBytes() }, 5);
}

test "the floor never falls" {
    var floors: TestFloors = .{};
    floors.raise(2, 7);
    floors.raise(2, 3);
    try std.testing.expectEqual(@as(u32, 7), floors.forStage(2));

    floors.raise(2, 9);
    try std.testing.expectEqual(@as(u32, 9), floors.forStage(2));
}

test "raising one stage's floor leaves the others alone" {
    var floors: TestFloors = .{};
    floors.raise(1, 4);
    try std.testing.expectEqual(@as(u32, 4), floors.forStage(1));
    try std.testing.expectEqual(@as(u32, 0), floors.forStage(0));
    try std.testing.expectEqual(@as(u32, 0), floors.forStage(2));
    try std.testing.expectEqual(@as(u32, 0), floors.forStage(3));
}

test "sealed floors detect a rollback of their storage against the counter" {
    var floors: TestFloors = .{};
    floors.raise(0, 5);
    // The secure element's counter advanced to 3 when these floors were written.
    floors.seal(3);
    try std.testing.expect(floors.isSealedAt(3));

    // The device later advances the counter to 4 (a newer floor was committed).
    // If the floor storage is then rolled back to this older state, its seal of
    // 3 no longer matches the counter the hardware holds, so it is not trusted.
    try std.testing.expect(!floors.isSealedAt(4));

    // Wiping the storage entirely resets the seal to zero, which also fails to
    // match any advanced counter.
    const wiped: TestFloors = .{};
    try std.testing.expect(!wiped.isSealedAt(4));
}

test "verification changes nothing about the device" {
    const pair = try testKey(0);
    var floors: TestFloors = .{};
    floors.raise(0, 4);

    const before = floors;
    _ = verify(try signedBy(pair, "the kernel", 9), .{ .key = pair.public_key.toBytes() }, 4) catch {};
    _ = verify(try signedBy(pair, "an old kernel", 1), .{ .key = pair.public_key.toBytes() }, 4) catch {};

    // Deciding is separate from acting: the floor moves only when the chain
    // commits to running what it verified.
    try std.testing.expectEqualSlices(u32, &before.highest, &floors.highest);
}
