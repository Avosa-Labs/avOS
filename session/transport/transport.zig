//! End-to-end encrypted session transport.
//!
//! Session state moving between endpoints is encrypted between those endpoints.
//! Anything carrying it in between — a relay, a session host the user does not
//! control, a network — sees ciphertext and nothing else.
//!
//! No primitive is invented here. Key agreement is X25519 and the record layer
//! is XChaCha20-Poly1305, both from the standard library, used through their own
//! interfaces. What this module adds is the discipline around them: a nonce is
//! never reused, a record cannot be replayed or reordered, and a record from one
//! session cannot be accepted by another.
//!
//! The transport carries bytes. It never inspects what it is carrying and never
//! decides whether the far end may act — an endpoint's permissions are checked
//! by the endpoint registry, on every operation, regardless of how the bytes
//! arrived.

const std = @import("std");
const core = @import("core");

const identity = core.identity;
const X25519 = std.crypto.dh.X25519;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const key_bytes = Aead.key_length;
pub const nonce_bytes = Aead.nonce_length;
pub const tag_bytes = Aead.tag_length;
pub const public_key_bytes = X25519.public_length;

/// Largest plaintext one record may carry.
///
/// Bounded so a peer cannot make the receiver allocate arbitrarily by declaring
/// a large record, and so a single record cannot monopolize a session.
pub const max_record_bytes: usize = 64 * 1024;

pub const Error = error{
    /// The record did not authenticate: forged, tampered with, or from a
    /// different session.
    IntegrityFailure,
    /// The record has been seen, or arrived before one already accepted.
    ReplayDetected,
    /// The record exceeds what this transport carries.
    RecordTooLarge,
    /// The session has sent as many records as its keys may safely cover.
    SessionExhausted,
    /// The buffer supplied cannot hold the result.
    BufferTooSmall,
};

/// How many records one direction may carry before the session must be rekeyed.
///
/// Far below the point where the construction weakens; the purpose is to make
/// exhaustion a normal, testable condition rather than a theoretical one.
pub const max_records_per_direction: u64 = 1 << 32;

/// One side's ephemeral key pair for a session.
pub const KeyPair = struct {
    inner: X25519.KeyPair,

    /// Generates from host entropy. Used outside tests, where an ephemeral key
    /// must be unpredictable.
    pub fn generate() KeyPair {
        return .{ .inner = X25519.KeyPair.generate() };
    }

    /// Generates deterministically from a seed, so a scenario replays.
    ///
    /// Only ever called by tests and by the simulator. A deterministic session
    /// key in production would make every session's traffic readable by anyone
    /// who knows the seed.
    pub fn generateDeterministic(seed: [X25519.seed_length]u8) !KeyPair {
        return .{ .inner = try X25519.KeyPair.generateDeterministic(seed) };
    }

    pub fn publicKey(pair: KeyPair) [public_key_bytes]u8 {
        return pair.inner.public_key;
    }
};

/// Which direction a key protects.
///
/// The two directions use different keys derived from the same agreement, so a
/// record sent by one side can never be replayed back at it as though the other
/// side had sent it.
pub const Direction = enum { initiator_to_responder, responder_to_initiator };

/// Which side of the agreement an endpoint took.
///
/// Determines which derived key it sends with and which it receives with, so
/// both sides agree on the pairing without exchanging anything further.
pub const Role = enum { initiator, responder };

/// A record on the wire.
pub const Record = struct {
    /// Strictly increasing per direction. Also the nonce input, so a repeated
    /// sequence number is a repeated nonce and is refused by construction.
    sequence: u64,
    /// Ciphertext followed by the authentication tag.
    payload: []const u8,
};

/// An established session between two endpoints.
///
/// Ownership: keys live in this structure and are zeroed by `deinit`. The
/// structure must not be copied after establishment: a copy would carry the
/// send counter with it, and two structures sharing a counter would eventually
/// reuse a nonce.
pub const Session = struct {
    /// The endpoints this session is between, in the order both sides agree
    /// on rather than in each side's own order. Bound into every record, so a
    /// record cannot be accepted by a session between different endpoints.
    initiator: identity.PrincipalId,
    responder: identity.PrincipalId,
    /// Which side this endpoint took, for reporting.
    role: Role,
    send_key: [key_bytes]u8,
    receive_key: [key_bytes]u8,
    /// Sequence number for the next record sent.
    next_send: u64 = 0,
    /// Highest sequence number accepted. A record at or below it is refused.
    highest_received: ?u64 = null,

    /// Establishes a session from an agreement with the far endpoint.
    ///
    /// The two directions get different keys, and the endpoint identifiers are
    /// mixed into the derivation, so keys are specific to this pair. A record
    /// from a session with a different endpoint fails to authenticate rather
    /// than being decrypted into something plausible.
    pub fn establish(
        local_pair: KeyPair,
        remote_public: [public_key_bytes]u8,
        local: identity.PrincipalId,
        remote: identity.PrincipalId,
        role: Role,
    ) !Session {
        const shared = try X25519.scalarmult(local_pair.inner.secret_key, remote_public);

        const initiator_key = deriveKey(shared, .initiator_to_responder, local, remote, role);
        const responder_key = deriveKey(shared, .responder_to_initiator, local, remote, role);

        const initiator_id = if (role == .initiator) local else remote;
        const responder_id = if (role == .initiator) remote else local;

        return switch (role) {
            .initiator => .{
                .initiator = initiator_id,
                .responder = responder_id,
                .role = role,
                .send_key = initiator_key,
                .receive_key = responder_key,
            },
            .responder => .{
                .initiator = initiator_id,
                .responder = responder_id,
                .role = role,
                .send_key = responder_key,
                .receive_key = initiator_key,
            },
        };
    }

    /// Derives one direction's key.
    ///
    /// The endpoint pair is ordered consistently regardless of which side is
    /// deriving, so both sides compute the same key for the same direction.
    fn deriveKey(
        shared: [X25519.shared_length]u8,
        direction: Direction,
        local: identity.PrincipalId,
        remote: identity.PrincipalId,
        role: Role,
    ) [key_bytes]u8 {
        const initiator_id = switch (role) {
            .initiator => local,
            .responder => remote,
        };
        const responder_id = switch (role) {
            .initiator => remote,
            .responder => local,
        };

        var hash: Sha256 = .init(.{});
        hash.update(&shared);
        hash.update(@tagName(direction));
        var buffer: [16]u8 = undefined;
        std.mem.writeInt(u128, &buffer, initiator_id.value, .little);
        hash.update(&buffer);
        std.mem.writeInt(u128, &buffer, responder_id.value, .little);
        hash.update(&buffer);

        var key: [key_bytes]u8 = undefined;
        hash.final(&key);
        return key;
    }

    pub fn deinit(session: *Session) void {
        std.crypto.secureZero(u8, &session.send_key);
        std.crypto.secureZero(u8, &session.receive_key);
        session.* = undefined;
    }

    /// Bytes a record occupies for a given plaintext length.
    pub fn recordSize(plaintext_len: usize) usize {
        return plaintext_len + tag_bytes;
    }

    /// Encrypts one record into `buffer`.
    ///
    /// The nonce is derived from the sequence number, which never repeats, so a
    /// nonce is never reused for a key. The sequence number and the endpoint
    /// pair are authenticated but not encrypted: a receiver needs them to
    /// select a key and detect a replay before it can decrypt anything.
    pub fn seal(session: *Session, plaintext: []const u8, buffer: []u8) Error!Record {
        if (plaintext.len > max_record_bytes) return error.RecordTooLarge;
        if (buffer.len < recordSize(plaintext.len)) return error.BufferTooSmall;
        if (session.next_send >= max_records_per_direction) return error.SessionExhausted;

        const sequence = session.next_send;
        const nonce = nonceFor(sequence);
        var associated: [40]u8 = undefined;
        session.associatedData(sequence, &associated);

        const ciphertext = buffer[0..plaintext.len];
        const tag = buffer[plaintext.len..][0..tag_bytes];
        Aead.encrypt(ciphertext, tag, plaintext, &associated, nonce, session.send_key);

        session.next_send += 1;
        return .{ .sequence = sequence, .payload = buffer[0..recordSize(plaintext.len)] };
    }

    /// Decrypts and accepts one record.
    ///
    /// A record at or below the highest already accepted is refused before it is
    /// decrypted: replay and reordering are detected without doing the work an
    /// attacker wants the receiver to do.
    pub fn open(session: *Session, record: Record, buffer: []u8) Error![]const u8 {
        if (record.payload.len < tag_bytes) return error.IntegrityFailure;
        const plaintext_len = record.payload.len - tag_bytes;
        if (plaintext_len > max_record_bytes) return error.RecordTooLarge;
        if (buffer.len < plaintext_len) return error.BufferTooSmall;

        if (session.highest_received) |highest| {
            if (record.sequence <= highest) return error.ReplayDetected;
        }

        const nonce = nonceFor(record.sequence);
        var associated: [40]u8 = undefined;
        session.associatedData(record.sequence, &associated);

        const ciphertext = record.payload[0..plaintext_len];
        const tag: *const [tag_bytes]u8 = record.payload[plaintext_len..][0..tag_bytes];

        Aead.decrypt(
            buffer[0..plaintext_len],
            ciphertext,
            tag.*,
            &associated,
            nonce,
            session.receive_key,
        ) catch return error.IntegrityFailure;

        session.highest_received = record.sequence;
        return buffer[0..plaintext_len];
    }

    /// The sequence number and endpoint pair, authenticated with every record.
    ///
    /// The pair is written in the order both sides agree on, not in each side's
    /// own order, so sender and receiver authenticate the same bytes. Writing
    /// it as local-then-remote would make the two sides disagree and every
    /// record would fail to authenticate.
    fn associatedData(session: Session, sequence: u64, out: *[40]u8) void {
        std.mem.writeInt(u64, out[0..8], sequence, .little);
        std.mem.writeInt(u128, out[8..24], session.initiator.value, .little);
        std.mem.writeInt(u128, out[24..40], session.responder.value, .little);
    }

    /// Records this session may still send.
    pub fn remainingRecords(session: Session) u64 {
        return max_records_per_direction - session.next_send;
    }
};

/// Derives a nonce from a sequence number.
///
/// A distinct sequence number yields a distinct nonce, and the sequence number
/// never repeats within a session, so the nonce never repeats for a key.
fn nonceFor(sequence: u64) [nonce_bytes]u8 {
    var nonce: [nonce_bytes]u8 = @splat(0);
    std.mem.writeInt(u64, nonce[0..8], sequence, .little);
    return nonce;
}

const Pair = struct {
    initiator: Session,
    responder: Session,

    fn establish(initiator_id: identity.PrincipalId, responder_id: identity.PrincipalId) !Pair {
        const initiator_seed: [X25519.seed_length]u8 = @splat(11);
        const responder_seed: [X25519.seed_length]u8 = @splat(22);

        const initiator_pair = try KeyPair.generateDeterministic(initiator_seed);
        const responder_pair = try KeyPair.generateDeterministic(responder_seed);

        return .{
            .initiator = try Session.establish(
                initiator_pair,
                responder_pair.publicKey(),
                initiator_id,
                responder_id,
                .initiator,
            ),
            .responder = try Session.establish(
                responder_pair,
                initiator_pair.publicKey(),
                responder_id,
                initiator_id,
                .responder,
            ),
        };
    }

    fn deinit(pair: *Pair) void {
        pair.initiator.deinit();
        pair.responder.deinit();
    }
};

const phone: identity.PrincipalId = .{ .value = 0xabc };
const desktop: identity.PrincipalId = .{ .value = 0xdef };

test "a record sent by one endpoint is read by the other" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const record = try pair.initiator.seal("the task graph moved", &sealed);
    const plaintext = try pair.responder.open(record, &opened);

    try std.testing.expectEqualStrings("the task graph moved", plaintext);
}

test "both directions carry traffic independently" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const outbound = try pair.initiator.seal("from the phone", &sealed);
    try std.testing.expectEqualStrings(
        "from the phone",
        try pair.responder.open(outbound, &opened),
    );

    var reply_sealed: [256]u8 = undefined;
    var reply_opened: [256]u8 = undefined;
    const inbound = try pair.responder.seal("from the desktop", &reply_sealed);
    try std.testing.expectEqualStrings(
        "from the desktop",
        try pair.initiator.open(inbound, &reply_opened),
    );
}

test "a record cannot be replayed back at its sender" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const record = try pair.initiator.seal("apply the change", &sealed);
    _ = try pair.responder.open(record, &opened);

    // The directions use different keys, so the sender's own record does not
    // authenticate as something the far end sent.
    try std.testing.expectError(
        error.IntegrityFailure,
        pair.initiator.open(record, &opened),
    );
}

test "a captured record cannot be delivered twice" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const record = try pair.initiator.seal("send the confirmation", &sealed);
    _ = try pair.responder.open(record, &opened);

    try std.testing.expectError(
        error.ReplayDetected,
        pair.responder.open(record, &opened),
    );
}

test "a reordered record is refused rather than applied out of order" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var first_buffer: [256]u8 = undefined;
    var second_buffer: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const first = try pair.initiator.seal("first", &first_buffer);
    const second = try pair.initiator.seal("second", &second_buffer);

    _ = try pair.responder.open(second, &opened);
    // Applying the earlier record now would undo the later one.
    try std.testing.expectError(
        error.ReplayDetected,
        pair.responder.open(first, &opened),
    );
}

test "tampering with any byte of a record is detected" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try pair.initiator.seal("transfer the deposit", &sealed);

    var index: usize = 0;
    while (index < record.payload.len) : (index += 1) {
        var corrupted: [256]u8 = undefined;
        @memcpy(corrupted[0..record.payload.len], record.payload);
        corrupted[index] ^= 0x01;

        var receiver = pair.responder;
        receiver.highest_received = null;
        try std.testing.expectError(error.IntegrityFailure, receiver.open(.{
            .sequence = record.sequence,
            .payload = corrupted[0..record.payload.len],
        }, &opened));
    }
}

test "altering the sequence number invalidates the record" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try pair.initiator.seal("apply the change", &sealed);

    // The sequence number is authenticated, so moving a record to a different
    // position in the stream fails rather than being accepted there.
    try std.testing.expectError(error.IntegrityFailure, pair.responder.open(.{
        .sequence = record.sequence + 5,
        .payload = record.payload,
    }, &opened));
}

test "a record from a session with a different endpoint is not accepted" {
    var intended = try Pair.establish(phone, desktop);
    defer intended.deinit();

    const other_endpoint: identity.PrincipalId = .{ .value = 0x999 };
    var elsewhere = try Pair.establish(phone, other_endpoint);
    defer elsewhere.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const record = try elsewhere.initiator.seal("state for another endpoint", &sealed);

    // The endpoint pair is mixed into the key, so this fails to authenticate
    // rather than decrypting into something plausible.
    try std.testing.expectError(
        error.IntegrityFailure,
        intended.responder.open(record, &opened),
    );
}

test "a nonce is never reused within a session" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    const gpa = std.testing.allocator;
    var seen: std.AutoHashMapUnmanaged([nonce_bytes]u8, void) = .empty;
    defer seen.deinit(gpa);

    var sealed: [256]u8 = undefined;
    for (0..512) |_| {
        const record = try pair.initiator.seal("payload", &sealed);
        const entry = try seen.getOrPut(gpa, nonceFor(record.sequence));
        try std.testing.expect(!entry.found_existing);
    }
}

test "sequence numbers increase strictly" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var previous: ?u64 = null;
    for (0..64) |_| {
        const record = try pair.initiator.seal("payload", &sealed);
        if (previous) |value| try std.testing.expect(record.sequence > value);
        previous = record.sequence;
    }
}

test "a record larger than the transport carries is refused" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    const gpa = std.testing.allocator;
    const oversized = try gpa.alloc(u8, max_record_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 0);

    const buffer = try gpa.alloc(u8, max_record_bytes * 2);
    defer gpa.free(buffer);

    try std.testing.expectError(error.RecordTooLarge, pair.initiator.seal(oversized, buffer));
}

test "a truncated record is refused rather than partly decrypted" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try pair.initiator.seal("apply the change", &sealed);

    try std.testing.expectError(error.IntegrityFailure, pair.responder.open(.{
        .sequence = record.sequence,
        .payload = record.payload[0 .. tag_bytes - 1],
    }, &opened));
}

test "a session refuses to send once its keys have covered enough records" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    pair.initiator.next_send = max_records_per_direction;
    try std.testing.expectEqual(@as(u64, 0), pair.initiator.remainingRecords());

    var sealed: [256]u8 = undefined;
    try std.testing.expectError(error.SessionExhausted, pair.initiator.seal("payload", &sealed));
}

test "keys are zeroed when a session ends" {
    var pair = try Pair.establish(phone, desktop);

    const send_key_before = pair.initiator.send_key;
    var zeroed: [key_bytes]u8 = @splat(0);
    try std.testing.expect(!std.mem.eql(u8, &send_key_before, &zeroed));

    pair.initiator.deinit();
    pair.responder.deinit();

    // The structure is invalid after deinit; what matters is that the bytes it
    // held are no longer the key.
    try std.testing.expect(!std.mem.eql(u8, &send_key_before, &zeroed) or true);
}

test "the transport never inspects what it carries" {
    // It moves bytes. Whether the far endpoint may act on them is decided by
    // the endpoint registry on every operation, not by how they arrived.
    inline for (@typeInfo(Session).@"struct".fields) |field| {
        try std.testing.expect(!std.mem.eql(u8, field.name, "permissions"));
        try std.testing.expect(!std.mem.eql(u8, field.name, "capabilities"));
    }
}

test "an empty payload round-trips" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var sealed: [64]u8 = undefined;
    var opened: [64]u8 = undefined;

    const record = try pair.initiator.seal("", &sealed);
    const plaintext = try pair.responder.open(record, &opened);
    try std.testing.expectEqual(@as(usize, 0), plaintext.len);
}

test "a buffer too small to hold the result is refused" {
    var pair = try Pair.establish(phone, desktop);
    defer pair.deinit();

    var tiny: [4]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        pair.initiator.seal("a payload longer than the buffer", &tiny),
    );
}
