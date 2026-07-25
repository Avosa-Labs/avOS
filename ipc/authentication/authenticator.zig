//! Authentication for inter-service messages.
//!
//! A message is accepted only when it was produced by a service holding the
//! expected signing key and has not been seen before. Both halves matter: a
//! signature alone proves origin but not freshness, and a captured message
//! replayed later is as damaging as a forged one when it authorizes a mutation.
//!
//! Signatures cover the encoded envelope exactly as it appeared on the wire.
//! Nothing is re-encoded before verification, so a peer cannot construct two
//! encodings of one message and have a signature cover the harmless one.
//!
//! No primitive is invented here. Signing is Ed25519 from the standard library,
//! used through its own API, with keys supplied by the caller.

const std = @import("std");
const envelope_schema = @import("../schema/envelope.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;

pub const Error = error{
    /// The signature does not verify against the expected key.
    IntegrityFailure,
    /// The sender is not a service this peer accepts messages from.
    UnknownSender,
    /// This exact message has been accepted before.
    ReplayDetected,
    /// The message arrived outside the window this peer accepts.
    OutsideFreshnessWindow,
    /// The signed message is malformed.
    Malformed,
};

/// A signed message: the encoded envelope and a signature over it.
pub const SignedMessage = struct {
    /// The sending service's identifier, used to select the verifying key.
    sender: u128,
    /// The encoded envelope, byte for byte as it was signed.
    body: []const u8,
    signature: [signature_bytes]u8,
};

/// The identity a service signs with. The secret half never leaves the service
/// that owns it and is never serialized by this module.
pub const SigningIdentity = struct {
    service: u128,
    key_pair: Ed25519.KeyPair,

    pub fn publicKey(identity: SigningIdentity) [public_key_bytes]u8 {
        return identity.key_pair.public_key.toBytes();
    }
};

/// Signs an encoded envelope.
///
/// The caller supplies the bytes it will actually send. Signing a
/// reconstruction instead would let the sent bytes differ from the signed ones.
pub fn sign(identity: SigningIdentity, body: []const u8) !SignedMessage {
    const signature = try identity.key_pair.sign(body, null);
    return .{
        .sender = identity.service,
        .body = body,
        .signature = signature.toBytes(),
    };
}

/// Verifies signatures and refuses anything already seen.
///
/// Ownership: the verifier owns its key table and its record of accepted
/// messages. `deinit` releases both.
///
/// Not threadsafe. One verifier belongs to one service's receive path; sharing
/// it across threads would need a lock on the replay record, which sits on the
/// path of every inbound message.
pub const Verifier = struct {
    gpa: std.mem.Allocator,
    /// Public keys of services this peer accepts messages from.
    trusted: std.AutoHashMapUnmanaged(u128, [public_key_bytes]u8) = .empty,
    /// Idempotency keys already accepted, per sender.
    seen: std.AutoHashMapUnmanaged(SeenKey, void) = .empty,
    /// The accepted keys in the order they arrived, so eviction removes the
    /// oldest rather than an arbitrary hashmap entry. Eviction order matters:
    /// dropping a recent key would reopen a shorter replay window than dropping
    /// the oldest, which is the least likely to still be replayed.
    order: std.ArrayListUnmanaged(SeenKey) = .empty,
    /// Ceiling on remembered messages. Without one the record grows with
    /// traffic and becomes its own exhaustion vector.
    max_remembered: usize = 4096,
    /// Accepted messages evicted because the record was full. A non-zero count
    /// means replay protection is degraded and the ceiling needs raising.
    evictions: u64 = 0,

    const SeenKey = struct {
        sender: u128,
        idempotency_key: u128,
    };

    pub fn init(gpa: std.mem.Allocator) Verifier {
        return .{ .gpa = gpa };
    }

    pub fn deinit(verifier: *Verifier) void {
        verifier.trusted.deinit(verifier.gpa);
        verifier.seen.deinit(verifier.gpa);
        verifier.order.deinit(verifier.gpa);
        verifier.* = undefined;
    }

    /// Records a service this peer will accept messages from.
    pub fn trust(verifier: *Verifier, service: u128, key: [public_key_bytes]u8) !void {
        try verifier.trusted.put(verifier.gpa, service, key);
    }

    /// Stops accepting messages from a service.
    ///
    /// Takes effect on the next message: a revoked service's outstanding
    /// signatures verify cryptographically but are no longer trusted.
    pub fn revokeTrust(verifier: *Verifier, service: u128) void {
        _ = verifier.trusted.remove(service);
    }

    pub fn trustsService(verifier: Verifier, service: u128) bool {
        return verifier.trusted.contains(service);
    }

    /// Verifies a message and decodes its envelope.
    ///
    /// The order matters. Origin is established before the message is parsed
    /// beyond what verification needs, so a hostile peer cannot reach the
    /// decoder's field handling without a valid signature from a trusted
    /// service.
    pub fn accept(
        verifier: *Verifier,
        message: SignedMessage,
        now_nanoseconds: i64,
    ) (Error || envelope_schema.DecodeError || std.mem.Allocator.Error)!envelope_schema.Envelope {
        const key_bytes = verifier.trusted.get(message.sender) orelse return error.UnknownSender;

        const public_key = Ed25519.PublicKey.fromBytes(key_bytes) catch return error.Malformed;
        const signature: Ed25519.Signature = .fromBytes(message.signature);
        signature.verify(message.body, public_key) catch return error.IntegrityFailure;

        const decoded = try envelope_schema.decode(message.body);

        // A message past its deadline is stale. This is the freshness gate the
        // replay record cannot provide on its own: once an old key is evicted,
        // only its expired deadline still keeps it out.
        if (decoded.deadline_nanoseconds != 0 and now_nanoseconds > decoded.deadline_nanoseconds) {
            return error.OutsideFreshnessWindow;
        }

        // Only a message that may mutate needs replay protection; a response or
        // a fault carries no effect to repeat.
        if (!decoded.kind.mayMutate()) return decoded;

        const seen_key: SeenKey = .{
            .sender = message.sender,
            .idempotency_key = decoded.idempotency_key,
        };
        if (verifier.seen.contains(seen_key)) return error.ReplayDetected;

        try verifier.rememberBounded(seen_key);
        return decoded;
    }

    /// Records a message as seen, evicting the oldest entry when full.
    ///
    /// Eviction removes the oldest key, tracked in `order`, rather than an
    /// arbitrary hashmap entry — so the replay window that stays protected is the
    /// most recent one, where a replay is most likely. Eviction is counted
    /// because losing replay protection is a security-relevant degradation, not a
    /// routine cache miss.
    fn rememberBounded(verifier: *Verifier, key: SeenKey) !void {
        // Reserve space for the new order entry before touching the set, so a
        // failed allocation leaves the record unchanged.
        try verifier.order.ensureUnusedCapacity(verifier.gpa, 1);
        if (verifier.seen.count() >= verifier.max_remembered and verifier.order.items.len > 0) {
            const victim = verifier.order.orderedRemove(0);
            _ = verifier.seen.remove(victim);
            verifier.evictions += 1;
        }
        try verifier.seen.put(verifier.gpa, key, {});
        verifier.order.appendAssumeCapacity(key);
    }

    pub fn rememberedCount(verifier: Verifier) usize {
        return verifier.seen.count();
    }
};

const Fixture = struct {
    identity: SigningIdentity,
    verifier: Verifier,
    buffer: [envelope_schema.max_message_bytes]u8 = undefined,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        // A fixed seed keeps the fixture deterministic; production identities
        // are generated from host entropy.
        const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(7);
        fixture.* = .{
            .identity = .{ .service = 0xa11ce, .key_pair = try .generateDeterministic(seed) },
            .verifier = .init(gpa),
        };
        try fixture.verifier.trust(fixture.identity.service, fixture.identity.publicKey());
    }

    fn deinit(fixture: *Fixture) void {
        fixture.verifier.deinit();
    }

    fn request(fixture: *Fixture, idempotency_key: u128) envelope_schema.Envelope {
        _ = fixture;
        return .{
            .version = envelope_schema.current_version,
            .kind = .request,
            .correlation = 1,
            .idempotency_key = idempotency_key,
            .principal = 0x1111,
            .task = 0x2222,
            .capability = 0x3333,
            .deadline_nanoseconds = 0,
            .method = "calendar.read",
            .payload = "body",
        };
    }
};

test "the verifier leaks nothing when an allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const identity: SigningIdentity = .{
                .service = 0x1,
                .key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(3)),
            };
            var verifier: Verifier = .init(gpa);
            defer verifier.deinit();
            try verifier.trust(identity.service, identity.publicKey());

            var buffer: [envelope_schema.max_message_bytes]u8 = undefined;
            const message: envelope_schema.Envelope = .{
                .version = envelope_schema.current_version,
                .kind = .request,
                .correlation = 1,
                .idempotency_key = 42,
                .principal = 0x9,
                .task = 0,
                .capability = 0,
                .deadline_nanoseconds = 0,
                .method = "calendar.read",
                .payload = "",
            };
            const body = try envelope_schema.encode(message, &buffer);
            _ = try verifier.accept(try sign(identity, body), 0);
        }
    }.run, .{});
}

test "a message past its deadline is refused as stale" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var message_envelope = fixture.request(5);
    message_envelope.deadline_nanoseconds = 1_000;
    const body = try envelope_schema.encode(message_envelope, &fixture.buffer);
    const message = try sign(fixture.identity, body);

    // Arriving after the deadline, it is refused before the replay record is even
    // touched, so an evicted old key cannot let it back in.
    try std.testing.expectError(error.OutsideFreshnessWindow, fixture.verifier.accept(message, 2_000));
    // At the deadline it is still fresh and accepted.
    _ = try fixture.verifier.accept(message, 1_000);
}

test "eviction drops the oldest accepted message first" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();
    fixture.verifier.max_remembered = 2;

    // Three distinct mutating messages; the third evicts the first.
    inline for (.{ 1, 2, 3 }) |idempotency| {
        var buffer: [envelope_schema.max_message_bytes]u8 = undefined;
        const body = try envelope_schema.encode(fixture.request(idempotency), &buffer);
        _ = try fixture.verifier.accept(try sign(fixture.identity, body), 0);
    }
    try std.testing.expectEqual(@as(u64, 1), fixture.verifier.evictions);

    // Message 1 was evicted, so re-presenting it is not caught as a replay.
    var buffer_one: [envelope_schema.max_message_bytes]u8 = undefined;
    const body_one = try envelope_schema.encode(fixture.request(1), &buffer_one);
    _ = try fixture.verifier.accept(try sign(fixture.identity, body_one), 0);

    // Message 3, the most recent, is still remembered and refused.
    var buffer_three: [envelope_schema.max_message_bytes]u8 = undefined;
    const body_three = try envelope_schema.encode(fixture.request(3), &buffer_three);
    try std.testing.expectError(error.ReplayDetected, fixture.verifier.accept(try sign(fixture.identity, body_three), 0));
}

test "a signed message from a trusted service is accepted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const body = try envelope_schema.encode(fixture.request(1), &fixture.buffer);
    const message = try sign(fixture.identity, body);

    const decoded = try fixture.verifier.accept(message, 0);
    try std.testing.expectEqualStrings("calendar.read", decoded.method);
}

test "a message from an untrusted service is refused before it is parsed" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const body = try envelope_schema.encode(fixture.request(1), &fixture.buffer);
    var message = try sign(fixture.identity, body);
    message.sender = 0xb0b;

    try std.testing.expectError(error.UnknownSender, fixture.verifier.accept(message, 0));
}

test "a tampered body fails verification" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const body = try envelope_schema.encode(fixture.request(1), &fixture.buffer);
    var message = try sign(fixture.identity, body);

    // Alter one byte of the signed body.
    var tampered: [envelope_schema.max_message_bytes]u8 = undefined;
    @memcpy(tampered[0..body.len], body);
    tampered[body.len - 1] ^= 0xff;
    message.body = tampered[0..body.len];

    try std.testing.expectError(error.IntegrityFailure, fixture.verifier.accept(message, 0));
}

test "a tampered signature fails verification" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const body = try envelope_schema.encode(fixture.request(1), &fixture.buffer);
    var message = try sign(fixture.identity, body);
    message.signature[0] ^= 0xff;

    try std.testing.expectError(error.IntegrityFailure, fixture.verifier.accept(message, 0));
}

test "a signature from one service does not authenticate another" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const other_seed: [Ed25519.KeyPair.seed_length]u8 = @splat(9);
    const impostor: SigningIdentity = .{
        .service = fixture.identity.service,
        .key_pair = try .generateDeterministic(other_seed),
    };

    const body = try envelope_schema.encode(fixture.request(1), &fixture.buffer);
    const message = try sign(impostor, body);

    // The sender field claims a trusted service, but the key does not match.
    try std.testing.expectError(error.IntegrityFailure, fixture.verifier.accept(message, 0));
}

test "a captured mutating message cannot be replayed" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const body = try envelope_schema.encode(fixture.request(0xdeadbeef), &fixture.buffer);
    const message = try sign(fixture.identity, body);

    _ = try fixture.verifier.accept(message, 0);
    // The identical message, validly signed, must not be honored twice.
    try std.testing.expectError(error.ReplayDetected, fixture.verifier.accept(message, 0));
}

test "distinct mutations from one service are each accepted" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    for (1..8) |index| {
        var body_buffer: [envelope_schema.max_message_bytes]u8 = undefined;
        const body = try envelope_schema.encode(fixture.request(@intCast(index)), &body_buffer);
        const message = try sign(fixture.identity, body);
        _ = try fixture.verifier.accept(message, 0);
    }
    try std.testing.expectEqual(@as(usize, 7), fixture.verifier.rememberedCount());
}

test "the same key from different services is not a replay" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const second_seed: [Ed25519.KeyPair.seed_length]u8 = @splat(11);
    const second: SigningIdentity = .{
        .service = 0xb0b,
        .key_pair = try .generateDeterministic(second_seed),
    };
    try fixture.verifier.trust(second.service, second.publicKey());

    const body = try envelope_schema.encode(fixture.request(42), &fixture.buffer);
    _ = try fixture.verifier.accept(try sign(fixture.identity, body), 0);

    var second_buffer: [envelope_schema.max_message_bytes]u8 = undefined;
    const second_body = try envelope_schema.encode(fixture.request(42), &second_buffer);
    _ = try fixture.verifier.accept(try sign(second, second_body), 0);
}

test "a response is not subject to replay protection" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    var response = fixture.request(0);
    response.kind = .response;

    const body = try envelope_schema.encode(response, &fixture.buffer);
    const message = try sign(fixture.identity, body);

    // A response carries no effect to repeat, so redelivery is harmless.
    _ = try fixture.verifier.accept(message, 0);
    _ = try fixture.verifier.accept(message, 0);
    try std.testing.expectEqual(@as(usize, 0), fixture.verifier.rememberedCount());
}

test "revoking trust stops the next message from a service" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const body = try envelope_schema.encode(fixture.request(1), &fixture.buffer);
    _ = try fixture.verifier.accept(try sign(fixture.identity, body), 0);

    fixture.verifier.revokeTrust(fixture.identity.service);
    try std.testing.expect(!fixture.verifier.trustsService(fixture.identity.service));

    var next_buffer: [envelope_schema.max_message_bytes]u8 = undefined;
    const next_body = try envelope_schema.encode(fixture.request(2), &next_buffer);
    try std.testing.expectError(
        error.UnknownSender,
        fixture.verifier.accept(try sign(fixture.identity, next_body), 0),
    );
}

test "the replay record is bounded and reports degradation" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    fixture.verifier.max_remembered = 8;

    for (1..32) |index| {
        var body_buffer: [envelope_schema.max_message_bytes]u8 = undefined;
        const body = try envelope_schema.encode(fixture.request(@intCast(index)), &body_buffer);
        _ = try fixture.verifier.accept(try sign(fixture.identity, body), 0);
    }

    // The record never grows past its ceiling, and the loss is visible.
    try std.testing.expect(fixture.verifier.rememberedCount() <= 8);
    try std.testing.expect(fixture.verifier.evictions > 0);
}

test "a malformed body is refused after the signature verifies" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // Validly signed rubbish must still fail to decode.
    const rubbish = [_]u8{ 1, 2, 3, 4, 5 };
    const message = try sign(fixture.identity, &rubbish);
    try std.testing.expectError(error.ProtocolMismatch, fixture.verifier.accept(message, 0));
}
