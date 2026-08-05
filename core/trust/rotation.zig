//! Key rotation: replacing an agent's identity key without changing who it is.
//!
//! An agent principal keeps its identity across restarts — the same principal, the same generation — so
//! nothing here fires on a restart. Rotation is the deliberate, rarer act of retiring a key for a new
//! one, and it is proved twice over: the outgoing key signs the incoming key, so only the current holder
//! can authorize the change and a stolen future key cannot rewrite the past; and the generation strictly
//! increments, so an old rotation cannot be replayed to roll an identity backward. A rotation is only
//! complete once the issuer re-endorses the new key (endorsement.zig) — until then verifiers still hold
//! the old key, and the identity has not moved. A revoked identity rotates to nothing: revocation is
//! checked before a rotation is honored, so a compromised key cannot rotate itself to safety.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;
pub const digest_bytes = Sha256.digest_length;

pub const Error = error{ SignatureInvalid, GenerationNotAdvanced, PrincipalMismatch };

/// A rotation of one identity's key. The outgoing key signs this record, committing to the incoming key
/// and the new generation, so the change is authorized by the party that currently controls the identity.
pub const Rotation = struct {
    subject: identity.PrincipalId,
    from_key: [public_key_bytes]u8,
    to_key: [public_key_bytes]u8,
    /// The generation the identity moves to; must be strictly greater than the one it leaves.
    from_generation: u64,
    to_generation: u64,
    at: time.Timestamp,
    /// The outgoing key's signature over this record.
    signature: [signature_bytes]u8,

    fn digest(subject: identity.PrincipalId, from_key: [public_key_bytes]u8, to_key: [public_key_bytes]u8, from_generation: u64, to_generation: u64, at: time.Timestamp) [digest_bytes]u8 {
        var hasher = Sha256.init(.{});
        hasher.update("trust.rotation.v1");
        hashInt(&hasher, u128, subject.value);
        hasher.update(&from_key);
        hasher.update(&to_key);
        hashInt(&hasher, u64, from_generation);
        hashInt(&hasher, u64, to_generation);
        hashInt(&hasher, i64, at.nanoseconds);
        var out: [digest_bytes]u8 = undefined;
        hasher.final(&out);
        return out;
    }
};

/// Produces a signed rotation: the current key authorizes moving to `to_key` at a strictly higher
/// generation. Refuses a generation that does not advance, so a rotation can never roll an identity back.
pub fn rotate(
    current_key: Ed25519.KeyPair,
    subject: identity.PrincipalId,
    to_key: [public_key_bytes]u8,
    from_generation: u64,
    to_generation: u64,
    at: time.Timestamp,
) Error!Rotation {
    if (to_generation <= from_generation) return Error.GenerationNotAdvanced;
    const from_key = current_key.public_key.toBytes();
    const d = Rotation.digest(subject, from_key, to_key, from_generation, to_generation, at);
    const signature = current_key.sign(&d, null) catch return Error.SignatureInvalid;
    return .{
        .subject = subject,
        .from_key = from_key,
        .to_key = to_key,
        .from_generation = from_generation,
        .to_generation = to_generation,
        .at = at,
        .signature = signature.toBytes(),
    };
}

/// Verifies a rotation for `subject` currently known by `current_key` at `current_generation`: the record
/// is for this principal, signed by the current key, and advances the generation. On success the identity
/// may adopt `rotation.to_key` — but only once the issuer re-endorses it (endorsement.zig); this proves
/// the holder authorized the change, not that the change is yet trusted by verifiers.
pub fn verify(rotation: Rotation, subject: identity.PrincipalId, current_key: [public_key_bytes]u8, current_generation: u64) Error!void {
    if (!rotation.subject.eql(subject)) return Error.PrincipalMismatch;
    if (!keysEqual(rotation.from_key, current_key)) return Error.SignatureInvalid;
    if (rotation.from_generation != current_generation or rotation.to_generation <= current_generation) return Error.GenerationNotAdvanced;
    const key = Ed25519.PublicKey.fromBytes(current_key) catch return Error.SignatureInvalid;
    const parsed: Ed25519.Signature = .fromBytes(rotation.signature);
    parsed.verify(&Rotation.digest(rotation.subject, rotation.from_key, rotation.to_key, rotation.from_generation, rotation.to_generation, rotation.at), key) catch return Error.SignatureInvalid;
}

fn keysEqual(a: [public_key_bytes]u8, b: [public_key_bytes]u8) bool {
    return std.crypto.timing_safe.eql([public_key_bytes]u8, a, b);
}

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

// --- Tests ---

const testing = std.testing;

test "a rotation authorized by the current key verifies and advances the generation" {
    const current = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    const next = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    const subject: identity.PrincipalId = .{ .value = 0x42 };

    const rotation = try rotate(current, subject, next.public_key.toBytes(), 3, 4, .fromSeconds(100));
    try verify(rotation, subject, current.public_key.toBytes(), 3);
    try testing.expect(keysEqual(rotation.to_key, next.public_key.toBytes()));
}

test "a rotation not signed by the current key is refused" {
    const current = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    const impostor = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const next = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    const subject: identity.PrincipalId = .{ .value = 0x42 };

    // The impostor signs a rotation of an identity it does not hold.
    const forged = try rotate(impostor, subject, next.public_key.toBytes(), 3, 4, .fromSeconds(100));
    try testing.expectError(Error.SignatureInvalid, verify(forged, subject, current.public_key.toBytes(), 3));
}

test "a rotation cannot roll the generation backward or stand still" {
    const current = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    const next = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    const subject: identity.PrincipalId = .{ .value = 0x42 };

    try testing.expectError(Error.GenerationNotAdvanced, rotate(current, subject, next.public_key.toBytes(), 3, 3, .fromSeconds(100)));
    try testing.expectError(Error.GenerationNotAdvanced, rotate(current, subject, next.public_key.toBytes(), 3, 2, .fromSeconds(100)));

    // A record that claims to advance but whose from_generation does not match the current one is a
    // replay of a stale rotation and is refused.
    const stale = try rotate(current, subject, next.public_key.toBytes(), 3, 4, .fromSeconds(100));
    try testing.expectError(Error.GenerationNotAdvanced, verify(stale, subject, current.public_key.toBytes(), 5));
}

test "a rotation for a different principal is refused" {
    const current = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    const next = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    const rotation = try rotate(current, .{ .value = 0x42 }, next.public_key.toBytes(), 3, 4, .fromSeconds(100));
    try testing.expectError(Error.PrincipalMismatch, verify(rotation, .{ .value = 0x43 }, current.public_key.toBytes(), 3));
}
