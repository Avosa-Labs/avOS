//! Proving who a principal is, and binding an endpoint to the human it serves.
//!
//! A principal identifier says which principal is acting; it does not prove the
//! actor is that principal. Authentication closes that gap: a principal that
//! holds identity material proves it by signing a fresh, single-use challenge,
//! and the authenticator accepts the proof once. A replayed challenge, a forged
//! one it never issued, a stale one, or a signature by the wrong key is refused.
//!
//! A session binds a device endpoint to the human it currently acts for, as a
//! short-lived credential. The binding expires on its own, so an endpoint left
//! unattended stops acting for the human without anyone revoking it.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");
const principal = @import("principal.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const nonce_bytes = 32;
pub const signature_bytes = Ed25519.Signature.encoded_length;

pub const Error = error{
    /// The challenge was never issued, or was already spent.
    UnknownChallenge,
    /// The challenge was issued but is past its window.
    ChallengeExpired,
    /// The subject holds no key to authenticate with.
    NoIdentityKey,
    /// The signature does not verify against the subject's key.
    BadSignature,
    /// The subject cannot act (revoked, suspended, or expired).
    Unauthorized,
} || std.mem.Allocator.Error;

/// A one-time value a principal must sign to prove itself.
pub const Challenge = struct {
    nonce: [nonce_bytes]u8,
    subject: identity.PrincipalId,
    expires_at: time.Timestamp,
};

/// Issues challenges and verifies the proofs, remembering which are outstanding
/// so each is honored exactly once.
///
/// Ownership: the authenticator owns its outstanding-challenge map; `deinit`
/// releases it. It reads the registry to resolve a subject's key but never
/// mutates it.
pub const Authenticator = struct {
    gpa: std.mem.Allocator,
    ids: *identity.Source,
    clock: time.Clock,
    registry: *const principal.Registry,
    window: time.Duration,
    outstanding: std.AutoHashMapUnmanaged([nonce_bytes]u8, Challenge) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        ids: *identity.Source,
        clock: time.Clock,
        registry: *const principal.Registry,
        window: time.Duration,
    ) Authenticator {
        return .{ .gpa = gpa, .ids = ids, .clock = clock, .registry = registry, .window = window };
    }

    pub fn deinit(authenticator: *Authenticator) void {
        authenticator.outstanding.deinit(authenticator.gpa);
        authenticator.* = undefined;
    }

    /// Issues a fresh challenge for `subject` to sign. The nonce is unpredictable
    /// and the challenge expires after the configured window.
    pub fn challenge(authenticator: *Authenticator, subject: identity.PrincipalId) !Challenge {
        var nonce: [nonce_bytes]u8 = undefined;
        authenticator.ids.bytes(&nonce);
        const value: Challenge = .{
            .nonce = nonce,
            .subject = subject,
            .expires_at = authenticator.clock.wall().plus(authenticator.window),
        };
        try authenticator.outstanding.put(authenticator.gpa, nonce, value);
        return value;
    }

    /// Verifies a signature over a challenge's nonce by its subject's key. A
    /// challenge verifies at most once: it is consumed here, so replaying the
    /// same nonce is refused as unknown.
    pub fn verify(authenticator: *Authenticator, presented: Challenge, signature: [signature_bytes]u8) Error!void {
        const issued = authenticator.outstanding.fetchRemove(presented.nonce) orelse
            return error.UnknownChallenge;
        const value = issued.value;

        if (!value.subject.eql(presented.subject)) return error.UnknownChallenge;
        if (!value.expires_at.isAfter(authenticator.clock.wall())) return error.ChallengeExpired;

        // The subject must still be able to act, and must hold a key to prove with.
        const subject = authenticator.registry.authorize(value.subject) catch return error.Unauthorized;
        const key_bytes = subject.public_key orelse return error.NoIdentityKey;

        const public_key = Ed25519.PublicKey.fromBytes(key_bytes) catch return error.BadSignature;
        const parsed: Ed25519.Signature = .fromBytes(signature);
        parsed.verify(&value.nonce, public_key) catch return error.BadSignature;
    }

    /// Outstanding challenges past their window, cleared so the map cannot grow
    /// without bound under a spray of challenge requests that never complete.
    pub fn expireStale(authenticator: *Authenticator) void {
        const now = authenticator.clock.wall();
        var stale: [64][nonce_bytes]u8 = undefined;
        var count: usize = 0;
        var iterator = authenticator.outstanding.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.expires_at.isAfter(now)) {
                if (count == stale.len) break;
                stale[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        for (stale[0..count]) |nonce| _ = authenticator.outstanding.remove(nonce);
    }

    pub fn outstandingCount(authenticator: Authenticator) usize {
        return authenticator.outstanding.count();
    }
};

/// A short-lived credential binding a device endpoint to the human it acts for.
pub const Session = struct {
    /// The session-kind principal this credential belongs to.
    session: identity.PrincipalId,
    /// The device the human is acting through.
    endpoint: identity.PrincipalId,
    /// The authenticated human the endpoint acts for.
    human: identity.PrincipalId,
    issued_at: time.Timestamp,
    expires_at: time.Timestamp,

    /// Whether the binding still holds at `now`. It lapses on its own so an
    /// unattended endpoint stops acting for the human without an explicit revoke.
    pub fn isValid(binding: Session, now: time.Timestamp) bool {
        return binding.expires_at.isAfter(now);
    }
};

const testing = std.testing;

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal.Registry,
    authenticator: Authenticator,
    human: identity.PrincipalId,
    key_pair: Ed25519.KeyPair,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(7);
        fixture.* = .{
            .ids = .initDeterministic(4242),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .authenticator = undefined,
            .human = .none,
            .key_pair = try .generateDeterministic(seed),
        };
        fixture.registry = .init(gpa, &fixture.ids, fixture.manual.clock());
        fixture.authenticator = .init(gpa, &fixture.ids, fixture.manual.clock(), &fixture.registry, .fromSeconds(60));
        fixture.human = try fixture.registry.enroll(.{
            .kind = .human,
            .display_name = "operator",
            .policy_domain = "local",
            .public_key = fixture.key_pair.public_key.toBytes(),
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.authenticator.deinit();
        fixture.registry.deinit();
    }

    fn sign(fixture: *Fixture, chal: Challenge) [signature_bytes]u8 {
        const signature = fixture.key_pair.sign(&chal.nonce, null) catch unreachable;
        return signature.toBytes();
    }
};

test "a correctly signed challenge authenticates once" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const chal = try fixture.authenticator.challenge(fixture.human);
    try fixture.authenticator.verify(chal, fixture.sign(chal));

    // The same challenge cannot be replayed: it was consumed on the first verify.
    try testing.expectError(error.UnknownChallenge, fixture.authenticator.verify(chal, fixture.sign(chal)));
}

test "a signature by the wrong key is refused" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const other_seed: [Ed25519.KeyPair.seed_length]u8 = @splat(9);
    const impostor: Ed25519.KeyPair = try .generateDeterministic(other_seed);

    const chal = try fixture.authenticator.challenge(fixture.human);
    const forged = (impostor.sign(&chal.nonce, null) catch unreachable).toBytes();
    try testing.expectError(error.BadSignature, fixture.authenticator.verify(chal, forged));
}

test "a challenge that was never issued is refused" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const forged: Challenge = .{ .nonce = @splat(0xAB), .subject = fixture.human, .expires_at = .fromSeconds(9_000) };
    try testing.expectError(error.UnknownChallenge, fixture.authenticator.verify(forged, fixture.sign(forged)));
}

test "an expired challenge is refused and stale ones are swept" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const chal = try fixture.authenticator.challenge(fixture.human);
    fixture.manual.advance(.fromSeconds(120));
    try testing.expectError(error.ChallengeExpired, fixture.authenticator.verify(chal, fixture.sign(chal)));

    // Another that also lapsed is cleared by the sweep, bounding the map.
    _ = try fixture.authenticator.challenge(fixture.human);
    fixture.manual.advance(.fromSeconds(120));
    fixture.authenticator.expireStale();
    try testing.expectEqual(@as(usize, 0), fixture.authenticator.outstandingCount());
}

test "a session binding lapses on its own" {
    const binding: Session = .{
        .session = .{ .value = 4 },
        .endpoint = .{ .value = 5 },
        .human = .{ .value = 1 },
        .issued_at = .fromSeconds(1_000),
        .expires_at = .fromSeconds(1_300),
    };
    try testing.expect(binding.isValid(.fromSeconds(1_200)));
    try testing.expect(!binding.isValid(.fromSeconds(1_400)));
}
