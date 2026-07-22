//! Encryption for durable state.
//!
//! State at rest is encrypted with a key derived for the store that holds it,
//! so compromising one store's key reveals that store and nothing else. Keys
//! are derived rather than stored: what persists is a salt and a generation
//! number, and the key material exists only while it is in use.
//!
//! Rotation replaces the key without rewriting history. Each record records
//! which generation sealed it, so a store can be read across a rotation while
//! new records use the new key. A generation that has been retired stops being
//! readable, which is what makes rotation meaningful rather than cosmetic.
//!
//! No primitive is invented. Derivation is HKDF-SHA256 and the record layer is
//! XChaCha20-Poly1305, both from the standard library through their own
//! interfaces.

const std = @import("std");
const core = @import("core");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

pub const key_bytes = Aead.key_length;
pub const nonce_bytes = Aead.nonce_length;
pub const tag_bytes = Aead.tag_length;
pub const salt_bytes = 32;

/// Largest plaintext one sealed record may carry.
pub const max_plaintext_bytes: usize = 1 << 20;

pub const Error = error{
    /// The record does not authenticate under the key that should open it.
    IntegrityFailure,
    /// The generation that sealed this record has been retired.
    KeyRetired,
    /// The record names a generation this store has never had.
    UnknownGeneration,
    /// The store has rotated as many times as it can represent.
    RotationExhausted,
    PlaintextTooLarge,
    BufferTooSmall,
};

/// Which store a key protects.
///
/// Mixed into derivation, so the same root produces a different key per store
/// and one store's key opens nothing else.
pub const Purpose = enum {
    task_state,
    capability_state,
    audit_ledger,
    package_state,
    session_state,
    secret_material,

    /// Whether a store of this purpose may be backed up.
    ///
    /// Secret material may not: a backup is a copy that outlives the device's
    /// protections, and the point of secret material is that it does not.
    pub fn mayBeBackedUp(purpose: Purpose) bool {
        return purpose != .secret_material;
    }
};

/// How many rotations a store can represent before it must be re-created.
pub const max_generation: u32 = std.math.maxInt(u32) - 1;

/// A sealed record as it sits at rest.
pub const Sealed = struct {
    /// Which key generation sealed it.
    generation: u32,
    /// Distinguishes records sealed under the same key.
    sequence: u64,
    /// Ciphertext followed by the authentication tag.
    payload: []const u8,
};

/// The key material for one store.
///
/// Ownership: derived key material lives in this structure and is zeroed by
/// `deinit`. The root key is borrowed and is never copied here — a structure
/// that held it would spread the most valuable secret across every store.
pub const StoreKeys = struct {
    purpose: Purpose,
    salt: [salt_bytes]u8,
    /// The generation new records are sealed under.
    current_generation: u32,
    /// Generations at or below this are retired and no longer open anything.
    retired_through: u32,
    /// Derived key for the current generation.
    current_key: [key_bytes]u8,
    /// Derived key for the immediately previous generation, kept so a store
    /// can be read across a rotation without being rewritten.
    previous_key: ?[key_bytes]u8,
    previous_generation: u32,
    /// Records sealed under the current generation.
    next_sequence: u64 = 0,

    /// Derives a store's keys from a root key and a salt.
    ///
    /// The salt persists with the store; the root key does not. Losing the root
    /// makes the store unreadable, which is the intended property.
    pub fn derive(
        root_key: []const u8,
        purpose: Purpose,
        salt: [salt_bytes]u8,
        generation: u32,
    ) StoreKeys {
        return .{
            .purpose = purpose,
            .salt = salt,
            .current_generation = generation,
            .retired_through = 0,
            .current_key = deriveKey(root_key, purpose, salt, generation),
            .previous_key = null,
            .previous_generation = 0,
        };
    }

    /// Derives the key for one generation of one store.
    ///
    /// Purpose and generation are both mixed in, so a key never opens a
    /// different store and never opens a different generation of its own.
    fn deriveKey(
        root_key: []const u8,
        purpose: Purpose,
        salt: [salt_bytes]u8,
        generation: u32,
    ) [key_bytes]u8 {
        const prk = Hkdf.extract(&salt, root_key);

        var context: [64]u8 = undefined;
        const name = @tagName(purpose);
        const used = @min(name.len, context.len - 4);
        @memcpy(context[0..used], name[0..used]);
        std.mem.writeInt(u32, context[used..][0..4], generation, .little);

        var key: [key_bytes]u8 = undefined;
        Hkdf.expand(&key, context[0 .. used + 4], prk);
        return key;
    }

    /// Rotates to a new generation.
    ///
    /// The outgoing key is kept so existing records stay readable. Retiring it
    /// is a separate act, because a store usually needs to be re-sealed before
    /// the old key can be discarded.
    pub fn rotate(keys: *StoreKeys, root_key: []const u8) Error!void {
        if (keys.current_generation >= max_generation) return error.RotationExhausted;

        keys.previous_key = keys.current_key;
        keys.previous_generation = keys.current_generation;
        keys.current_generation += 1;
        keys.current_key = deriveKey(
            root_key,
            keys.purpose,
            keys.salt,
            keys.current_generation,
        );
        keys.next_sequence = 0;
    }

    /// Retires every generation at or below `generation`.
    ///
    /// A retired generation opens nothing. This is what makes rotation more
    /// than cosmetic: until it happens, a leaked old key still reads the store.
    pub fn retireThrough(keys: *StoreKeys, generation: u32) void {
        keys.retired_through = @max(keys.retired_through, generation);
        if (keys.previous_key != null and keys.previous_generation <= generation) {
            std.crypto.secureZero(u8, &keys.previous_key.?);
            keys.previous_key = null;
        }
    }

    pub fn deinit(keys: *StoreKeys) void {
        std.crypto.secureZero(u8, &keys.current_key);
        if (keys.previous_key) |*previous| std.crypto.secureZero(u8, previous);
        keys.* = undefined;
    }

    /// Bytes a sealed record occupies for a given plaintext length.
    pub fn sealedSize(plaintext_len: usize) usize {
        return plaintext_len + tag_bytes;
    }

    /// Seals a record under the current generation.
    pub fn seal(keys: *StoreKeys, plaintext: []const u8, buffer: []u8) Error!Sealed {
        if (plaintext.len > max_plaintext_bytes) return error.PlaintextTooLarge;
        if (buffer.len < sealedSize(plaintext.len)) return error.BufferTooSmall;

        const sequence = keys.next_sequence;
        const nonce = nonceFor(keys.current_generation, sequence);
        var associated: [12]u8 = undefined;
        associatedData(keys.purpose, sequence, &associated);

        const ciphertext = buffer[0..plaintext.len];
        const tag = buffer[plaintext.len..][0..tag_bytes];
        Aead.encrypt(ciphertext, tag, plaintext, &associated, nonce, keys.current_key);

        keys.next_sequence += 1;
        return .{
            .generation = keys.current_generation,
            .sequence = sequence,
            .payload = buffer[0..sealedSize(plaintext.len)],
        };
    }

    /// Opens a record sealed under the current or the previous generation.
    pub fn open(keys: *const StoreKeys, record: Sealed, buffer: []u8) Error![]const u8 {
        if (record.payload.len < tag_bytes) return error.IntegrityFailure;
        const plaintext_len = record.payload.len - tag_bytes;
        if (plaintext_len > max_plaintext_bytes) return error.PlaintextTooLarge;
        if (buffer.len < plaintext_len) return error.BufferTooSmall;

        if (record.generation <= keys.retired_through) return error.KeyRetired;

        const key = if (record.generation == keys.current_generation)
            keys.current_key
        else if (keys.previous_key != null and record.generation == keys.previous_generation)
            keys.previous_key.?
        else
            return error.UnknownGeneration;

        const nonce = nonceFor(record.generation, record.sequence);
        var associated: [12]u8 = undefined;
        associatedData(keys.purpose, record.sequence, &associated);

        const ciphertext = record.payload[0..plaintext_len];
        const tag: *const [tag_bytes]u8 = record.payload[plaintext_len..][0..tag_bytes];

        Aead.decrypt(
            buffer[0..plaintext_len],
            ciphertext,
            tag.*,
            &associated,
            nonce,
            key,
        ) catch return error.IntegrityFailure;

        return buffer[0..plaintext_len];
    }
};

/// The nonce for one record.
///
/// Generation and sequence together never repeat: the sequence restarts at
/// each rotation, and the generation advances, so no pair recurs for a key.
fn nonceFor(generation: u32, sequence: u64) [nonce_bytes]u8 {
    var nonce: [nonce_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, nonce[0..4], generation, .little);
    std.mem.writeInt(u64, nonce[4..12], sequence, .little);
    return nonce;
}

/// What is authenticated alongside every record.
///
/// The generation is not repeated here: it is already bound through the nonce,
/// so a record cannot be opened under a different one.
fn associatedData(purpose: Purpose, sequence: u64, out: *[12]u8) void {
    std.mem.writeInt(u32, out[0..4], @as(u32, @intFromEnum(purpose)) + 1, .little);
    std.mem.writeInt(u64, out[4..12], sequence, .little);
}

const device_root = "a root key held by the device, never written to a store";
const store_salt: [salt_bytes]u8 = @splat(7);

test "a record round-trips under the key that sealed it" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const record = try keys.seal("the task reached running", &sealed);
    try std.testing.expectEqualStrings(
        "the task reached running",
        try keys.open(record, &opened),
    );
}

test "state at rest is ciphertext" {
    var keys: StoreKeys = .derive(device_root, .audit_ledger, store_salt, 1);
    defer keys.deinit();

    var sealed: [256]u8 = undefined;
    const record = try keys.seal("the agent read the calendar", &sealed);

    try std.testing.expect(std.mem.indexOf(u8, record.payload, "calendar") == null);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, "agent") == null);
}

test "one store's key opens nothing else" {
    var task_keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer task_keys.deinit();
    var audit_keys: StoreKeys = .derive(device_root, .audit_ledger, store_salt, 1);
    defer audit_keys.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try task_keys.seal("task state", &sealed);

    // Compromising one store must not reveal another, even under the same root.
    try std.testing.expectError(error.IntegrityFailure, audit_keys.open(record, &opened));
}

test "a different root key opens nothing" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();
    var wrong: StoreKeys = .derive("a different root key entirely", .task_state, store_salt, 1);
    defer wrong.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try keys.seal("task state", &sealed);

    try std.testing.expectError(error.IntegrityFailure, wrong.open(record, &opened));
}

test "a different salt opens nothing" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    const other_salt: [salt_bytes]u8 = @splat(9);
    var other: StoreKeys = .derive(device_root, .task_state, other_salt, 1);
    defer other.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try keys.seal("task state", &sealed);

    try std.testing.expectError(error.IntegrityFailure, other.open(record, &opened));
}

test "rotation keeps existing records readable" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var before_rotation: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const before = try keys.seal("sealed before rotation", &before_rotation);

    try keys.rotate(device_root);

    // Rotating must not make a store unreadable; that would be data loss
    // dressed up as security.
    try std.testing.expectEqualStrings(
        "sealed before rotation",
        try keys.open(before, &opened),
    );

    var after_rotation: [256]u8 = undefined;
    const after = try keys.seal("sealed after rotation", &after_rotation);
    try std.testing.expectEqual(@as(u32, 2), after.generation);
    try std.testing.expectEqualStrings(
        "sealed after rotation",
        try keys.open(after, &opened),
    );
}

test "retiring a generation stops it opening anything" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var before_rotation: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const before = try keys.seal("sealed before rotation", &before_rotation);

    try keys.rotate(device_root);
    keys.retireThrough(1);

    // Until retirement, a leaked old key still reads the store. This is what
    // makes rotation meaningful.
    try std.testing.expectError(error.KeyRetired, keys.open(before, &opened));

    var after_rotation: [256]u8 = undefined;
    const after = try keys.seal("sealed after rotation", &after_rotation);
    try std.testing.expectEqualStrings("sealed after rotation", try keys.open(after, &opened));
}

test "a record from a generation the store never had is refused" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try keys.seal("task state", &sealed);

    try std.testing.expectError(error.UnknownGeneration, keys.open(.{
        .generation = 99,
        .sequence = record.sequence,
        .payload = record.payload,
    }, &opened));
}

test "tampering with any byte of a sealed record is detected" {
    var keys: StoreKeys = .derive(device_root, .capability_state, store_salt, 1);
    defer keys.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try keys.seal("the capability was revoked", &sealed);

    var index: usize = 0;
    while (index < record.payload.len) : (index += 1) {
        var corrupted: [256]u8 = undefined;
        @memcpy(corrupted[0..record.payload.len], record.payload);
        corrupted[index] ^= 0x01;

        try std.testing.expectError(error.IntegrityFailure, keys.open(.{
            .generation = record.generation,
            .sequence = record.sequence,
            .payload = corrupted[0..record.payload.len],
        }, &opened));
    }
}

test "moving a record to a different position is detected" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var first_buffer: [256]u8 = undefined;
    var second_buffer: [256]u8 = undefined;
    var opened: [256]u8 = undefined;

    const first = try keys.seal("first record", &first_buffer);
    _ = try keys.seal("second record", &second_buffer);

    // The sequence is authenticated, so a record cannot be replayed at another
    // position in the store.
    try std.testing.expectError(error.IntegrityFailure, keys.open(.{
        .generation = first.generation,
        .sequence = first.sequence + 1,
        .payload = first.payload,
    }, &opened));
}

test "a nonce never repeats within a store, including across rotation" {
    const gpa = std.testing.allocator;
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var seen: std.AutoHashMapUnmanaged([nonce_bytes]u8, void) = .empty;
    defer seen.deinit(gpa);

    var sealed: [256]u8 = undefined;
    for (0..3) |_| {
        for (0..128) |_| {
            const record = try keys.seal("payload", &sealed);
            const entry = try seen.getOrPut(gpa, nonceFor(record.generation, record.sequence));
            try std.testing.expect(!entry.found_existing);
        }
        try keys.rotate(device_root);
    }
}

test "secret material is never backed up" {
    for (std.enums.values(Purpose)) |purpose| {
        const backable = purpose != .secret_material;
        try std.testing.expectEqual(backable, purpose.mayBeBackedUp());
    }
}

test "rotation is bounded rather than wrapping" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, max_generation);
    defer keys.deinit();

    // Wrapping would reuse a generation, and with it a nonce.
    try std.testing.expectError(error.RotationExhausted, keys.rotate(device_root));
}

test "an oversized plaintext is refused" {
    const gpa = std.testing.allocator;
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    const oversized = try gpa.alloc(u8, max_plaintext_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 0);

    const buffer = try gpa.alloc(u8, max_plaintext_bytes * 2);
    defer gpa.free(buffer);

    try std.testing.expectError(error.PlaintextTooLarge, keys.seal(oversized, buffer));
}

test "a truncated record is refused rather than partly decrypted" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var sealed: [256]u8 = undefined;
    var opened: [256]u8 = undefined;
    const record = try keys.seal("task state", &sealed);

    try std.testing.expectError(error.IntegrityFailure, keys.open(.{
        .generation = record.generation,
        .sequence = record.sequence,
        .payload = record.payload[0 .. tag_bytes - 1],
    }, &opened));
}

test "an empty record round-trips" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    var sealed: [64]u8 = undefined;
    var opened: [64]u8 = undefined;

    const record = try keys.seal("", &sealed);
    try std.testing.expectEqual(@as(usize, 0), (try keys.open(record, &opened)).len);
}

test "derivation is deterministic for the same inputs" {
    var first: StoreKeys = .derive(device_root, .task_state, store_salt, 3);
    defer first.deinit();
    var second: StoreKeys = .derive(device_root, .task_state, store_salt, 3);
    defer second.deinit();

    // A store re-opened after a restart must derive the same key, or the state
    // it wrote before would be unreadable.
    try std.testing.expectEqualSlices(u8, &first.current_key, &second.current_key);
}

test "each generation derives a distinct key" {
    const gpa = std.testing.allocator;
    var seen: std.AutoHashMapUnmanaged([key_bytes]u8, void) = .empty;
    defer seen.deinit(gpa);

    for (1..32) |generation| {
        var keys: StoreKeys = .derive(device_root, .task_state, store_salt, @intCast(generation));
        defer keys.deinit();
        const entry = try seen.getOrPut(gpa, keys.current_key);
        try std.testing.expect(!entry.found_existing);
    }
}

test "the key material is not the root key" {
    var keys: StoreKeys = .derive(device_root, .task_state, store_salt, 1);
    defer keys.deinit();

    // A store holding the root would spread the most valuable secret across
    // every store on the device.
    try std.testing.expect(std.mem.indexOf(u8, &keys.current_key, device_root[0..8]) == null);
    inline for (@typeInfo(StoreKeys).@"struct".fields) |field| {
        try std.testing.expect(!std.mem.eql(u8, field.name, "root_key"));
    }
}
