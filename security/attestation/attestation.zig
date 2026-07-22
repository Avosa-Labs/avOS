//! Stating what this device booted, to someone who does not trust it.
//!
//! An attestation is a signed statement about a boot: these stages ran, in this
//! order, at these versions, on this device. It is useful precisely because the
//! device making it cannot forge it — the key that signs is held where software
//! on the device cannot read it, which is why the signer here is an interface
//! rather than a key.
//!
//! What an attestation does not say is that the device is safe. It says what
//! ran. Deciding whether that is acceptable is the verifier's job, and a
//! verifier that treats "signature valid" as "device trustworthy" has skipped
//! the only part that required judgement.
//!
//! Freshness comes from the verifier, not the device. A quote answers a
//! challenge the verifier chose, so a quote captured from an earlier exchange
//! answers a question nobody asked and is refused.

const std = @import("std");
const boot = @import("boot");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_bytes = Sha256.digest_length;
pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;
pub const challenge_bytes = 32;

/// Domain separator.
///
/// Everything this key signs is signed over a statement that names what kind of
/// statement it is, so a quote can never be presented as any other signature
/// the same key produced.
const context = "attestation quote v1";

pub const Error = error{
    /// Not signed by the key the verifier accepts, or signed over other
    /// content.
    SignatureRejected,
    /// The quote answers a different challenge. Either it is stale, or it was
    /// captured from another exchange.
    ChallengeMismatch,
    /// The quote is from a boot at or before one already seen from this device.
    NotFresh,
    /// The signer refused. Reported rather than substituted with an unsigned
    /// quote, because an unsigned quote is not a weaker attestation but an
    /// absent one.
    SignerUnavailable,
};

/// A challenge issued by whoever is asking.
///
/// The verifier chooses it, so only the verifier can decide a quote is fresh.
/// A device that supplied its own nonce would be attesting to its own
/// timeliness, which is the thing in question.
pub const Challenge = struct {
    nonce: [challenge_bytes]u8,

    /// Issues an unpredictable challenge.
    ///
    /// The entropy is supplied by the verifier rather than taken from wherever
    /// this code happens to run, because the verifier is the party that has to
    /// believe the challenge was unpredictable.
    pub fn issue(entropy: std.Random) Challenge {
        var nonce: [challenge_bytes]u8 = undefined;
        entropy.bytes(&nonce);
        return .{ .nonce = nonce };
    }
};

/// What the device says about its boot.
pub const Statement = struct {
    /// The summary of everything measured, from the boot chain.
    measurements: [digest_bytes]u8,
    /// How many times this device has booted. Monotonic, held where the running
    /// system cannot lower it.
    boot_counter: u64,
    /// The challenge being answered.
    nonce: [challenge_bytes]u8,

    /// The bytes signed.
    ///
    /// Every field is covered and each is fixed-width, so no two distinct
    /// statements can produce the same bytes by moving a boundary between
    /// fields.
    fn digest(statement: Statement) [digest_bytes]u8 {
        var hash: Sha256 = .init(.{});
        hash.update(context);
        hash.update(&statement.measurements);
        var counter: [8]u8 = undefined;
        std.mem.writeInt(u64, &counter, statement.boot_counter, .little);
        hash.update(&counter);
        hash.update(&statement.nonce);
        var result: [digest_bytes]u8 = undefined;
        hash.final(&result);
        return result;
    }
};

/// A signed statement.
pub const Quote = struct {
    statement: Statement,
    signature: [signature_bytes]u8,
};

/// Whatever holds the attestation key.
///
/// An interface rather than a key, because the whole value of an attestation
/// rests on the signing key being somewhere the software making the statement
/// cannot read. On real hardware this is the secure element; in tests it is a
/// key in memory, and the difference is invisible to everything above.
pub const Signer = struct {
    context_pointer: *anyopaque,
    signFn: *const fn (context_pointer: *anyopaque, digest: [digest_bytes]u8) ?[signature_bytes]u8,

    fn sign(signer: Signer, digest: [digest_bytes]u8) ?[signature_bytes]u8 {
        return signer.signFn(signer.context_pointer, digest);
    }
};

/// Produces a quote answering a challenge.
pub fn quote(
    signer: Signer,
    chain: *const boot.chain.Chain,
    boot_counter: u64,
    challenge: Challenge,
) Error!Quote {
    const statement: Statement = .{
        .measurements = chain.summary(),
        .boot_counter = boot_counter,
        .nonce = challenge.nonce,
    };
    const signature = signer.sign(statement.digest()) orelse return error.SignerUnavailable;
    return .{ .statement = statement, .signature = signature };
}

/// What a verifier remembers about a device between exchanges.
pub const Seen = struct {
    /// The highest boot counter accepted from this device.
    highest_boot_counter: u64 = 0,

    fn record(seen: *Seen, counter: u64) void {
        seen.highest_boot_counter = @max(seen.highest_boot_counter, counter);
    }
};

/// Checks a quote and returns what the device says ran.
///
/// Returns the measurement summary rather than a boolean, so a caller has to
/// look at what booted in order to use the result at all. A function returning
/// "valid" invites treating a signature check as a trust decision.
pub fn verify(
    presented: Quote,
    device_key: [public_key_bytes]u8,
    challenge: Challenge,
    seen: *Seen,
) Error![digest_bytes]u8 {
    if (!std.crypto.timing_safe.eql(
        [challenge_bytes]u8,
        presented.statement.nonce,
        challenge.nonce,
    )) return error.ChallengeMismatch;

    // A replayed quote from an earlier boot of the same device would carry a
    // counter no higher than one already accepted.
    if (presented.statement.boot_counter <= seen.highest_boot_counter) return error.NotFresh;

    const key = Ed25519.PublicKey.fromBytes(device_key) catch return error.SignatureRejected;
    const signature: Ed25519.Signature = .fromBytes(presented.signature);
    signature.verify(&presented.statement.digest(), key) catch return error.SignatureRejected;

    seen.record(presented.statement.boot_counter);
    return presented.statement.measurements;
}

/// A signer backed by a key in memory.
///
/// For tests and for the simulator. It is deliberately not exported: a key in
/// memory is exactly what an attestation key must not be, and making this
/// available would let a build substitute it for the secure element without
/// anything failing.
const MemorySigner = struct {
    pair: Ed25519.KeyPair,
    /// Set to make signing fail, so the refusal path is reachable in a test.
    unavailable: bool = false,

    fn signer(memory: *MemorySigner) Signer {
        return .{ .context_pointer = memory, .signFn = signWith };
    }

    fn signWith(context_pointer: *anyopaque, digest: [digest_bytes]u8) ?[signature_bytes]u8 {
        const memory: *MemorySigner = @ptrCast(@alignCast(context_pointer));
        if (memory.unavailable) return null;
        const signature = memory.pair.sign(&digest, null) catch return null;
        return signature.toBytes();
    }
};

const Fixture = struct {
    manual: @import("core").time.ManualClock,
    device: MemorySigner,
    keys: [boot.chain.Stage.count]Ed25519.KeyPair,
    chain: boot.chain.Chain,

    fn init(fixture: *Fixture, kernel_contents: []const u8) !void {
        fixture.* = .{
            .manual = .init(.fromSeconds(1_000)),
            .device = .{ .pair = try Ed25519.KeyPair.generateDeterministic(@splat(11)) },
            .keys = undefined,
            .chain = undefined,
        };
        for (&fixture.keys, 0..) |*pair, index| {
            const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(@intCast(40 + index));
            pair.* = try .generateDeterministic(seed);
        }
        var public: [boot.chain.Stage.count][boot.verified.public_key_bytes]u8 = undefined;
        for (&public, fixture.keys) |*slot, pair| slot.* = pair.public_key.toBytes();
        fixture.chain = .init(fixture.manual.clock(), public, .{});

        try fixture.advance(.bootloader, "the bootloader");
        try fixture.advance(.kernel, kernel_contents);
        try fixture.advance(.control_plane, "the control plane");
    }

    fn advance(fixture: *Fixture, stage: boot.chain.Stage, contents: []const u8) !void {
        const digest = boot.measurements.digestOf(contents);
        const signature = try fixture.keys[@intFromEnum(stage)].sign(&digest, null);
        try fixture.chain.advance(.{
            .stage = stage,
            .image = .{
                .contents = contents,
                .version = 1,
                .signature = signature.toBytes(),
            },
        });
    }

    fn devicePublicKey(fixture: *const Fixture) [public_key_bytes]u8 {
        return fixture.device.pair.public_key.toBytes();
    }
};

const sample_challenge: Challenge = .{ .nonce = @splat(7) };

test "a quote states what booted" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    const presented = try quote(fixture.device.signer(), &fixture.chain, 1, sample_challenge);
    var seen: Seen = .{};
    const attested = try verify(presented, fixture.devicePublicKey(), sample_challenge, &seen);

    try std.testing.expectEqualSlices(u8, &fixture.chain.summary(), &attested);
}

test "a quote from a device that booted something else says so" {
    var expected: Fixture = undefined;
    try Fixture.init(&expected, "the kernel");

    var substituted: Fixture = undefined;
    try Fixture.init(&substituted, "a substituted kernel");

    const presented = try quote(
        substituted.device.signer(),
        &substituted.chain,
        1,
        sample_challenge,
    );
    var seen: Seen = .{};
    const attested = try verify(
        presented,
        substituted.devicePublicKey(),
        sample_challenge,
        &seen,
    );

    // The signature is perfectly valid. The verifier still has to look at what
    // it says, which is the whole point of returning the summary.
    try std.testing.expect(!std.mem.eql(u8, &expected.chain.summary(), &attested));
}

test "a quote answering a different challenge is refused" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    const presented = try quote(fixture.device.signer(), &fixture.chain, 1, sample_challenge);
    var seen: Seen = .{};
    const other: Challenge = .{ .nonce = @splat(8) };

    try std.testing.expectError(
        error.ChallengeMismatch,
        verify(presented, fixture.devicePublicKey(), other, &seen),
    );
}

test "a captured quote replayed against the same challenge is refused" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    const presented = try quote(fixture.device.signer(), &fixture.chain, 4, sample_challenge);
    var seen: Seen = .{};
    _ = try verify(presented, fixture.devicePublicKey(), sample_challenge, &seen);

    // Even the exact challenge it answered does not let it be presented twice:
    // the boot it describes has already been accounted for.
    try std.testing.expectError(
        error.NotFresh,
        verify(presented, fixture.devicePublicKey(), sample_challenge, &seen),
    );
}

test "a quote from an earlier boot is refused after a later one" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    var seen: Seen = .{};
    const later = try quote(fixture.device.signer(), &fixture.chain, 9, sample_challenge);
    _ = try verify(later, fixture.devicePublicKey(), sample_challenge, &seen);

    const earlier = try quote(fixture.device.signer(), &fixture.chain, 3, sample_challenge);
    try std.testing.expectError(
        error.NotFresh,
        verify(earlier, fixture.devicePublicKey(), sample_challenge, &seen),
    );
}

test "what the verifier remembers never goes backwards" {
    var seen: Seen = .{};
    seen.record(10);
    seen.record(2);
    try std.testing.expectEqual(@as(u64, 10), seen.highest_boot_counter);
}

test "a quote signed by another device is refused" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    var impostor: MemorySigner = .{
        .pair = try Ed25519.KeyPair.generateDeterministic(@splat(99)),
    };
    const presented = try quote(impostor.signer(), &fixture.chain, 1, sample_challenge);

    var seen: Seen = .{};
    try std.testing.expectError(
        error.SignatureRejected,
        verify(presented, fixture.devicePublicKey(), sample_challenge, &seen),
    );
}

test "a tampered statement is refused" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");
    var seen: Seen = .{};

    // Every field is covered by the signature, so editing any of them breaks it.
    var edited_measurements = try quote(fixture.device.signer(), &fixture.chain, 1, sample_challenge);
    edited_measurements.statement.measurements[0] ^= 0xff;
    try std.testing.expectError(
        error.SignatureRejected,
        verify(edited_measurements, fixture.devicePublicKey(), sample_challenge, &seen),
    );

    var edited_counter = try quote(fixture.device.signer(), &fixture.chain, 1, sample_challenge);
    edited_counter.statement.boot_counter = 500;
    try std.testing.expectError(
        error.SignatureRejected,
        verify(edited_counter, fixture.devicePublicKey(), sample_challenge, &seen),
    );
}

test "a quote cannot be moved onto another challenge" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    var moved = try quote(fixture.device.signer(), &fixture.chain, 1, sample_challenge);
    const other: Challenge = .{ .nonce = @splat(8) };
    moved.statement.nonce = other.nonce;

    // The nonce is inside the signature, so re-labelling the quote to answer a
    // different challenge invalidates it rather than relocating it.
    var seen: Seen = .{};
    try std.testing.expectError(
        error.SignatureRejected,
        verify(moved, fixture.devicePublicKey(), other, &seen),
    );
}

test "a signer that refuses produces no quote at all" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");
    fixture.device.unavailable = true;

    // Not a weaker attestation: an absent one. Substituting an unsigned quote
    // here would put the decision in the hands of whoever forgot to check.
    try std.testing.expectError(
        error.SignerUnavailable,
        quote(fixture.device.signer(), &fixture.chain, 1, sample_challenge),
    );
}

test "challenges are unpredictable" {
    var source: std.Random.DefaultCsprng = .init(@splat(3));
    const entropy = source.random();
    const first = Challenge.issue(entropy);
    const second = Challenge.issue(entropy);
    try std.testing.expect(!std.mem.eql(u8, &first.nonce, &second.nonce));
}

test "a quote over a halted boot attests to a halted boot" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    var stopped: Fixture = undefined;
    try Fixture.init(&stopped, "the kernel");
    // A chain that measured nothing must not summarize to the same value as one
    // that completed, or a device that failed to boot could attest as one that
    // did.
    stopped.chain.log.recorded = 0;

    const complete = try quote(fixture.device.signer(), &fixture.chain, 1, sample_challenge);
    const halted = try quote(stopped.device.signer(), &stopped.chain, 1, sample_challenge);

    try std.testing.expect(!std.mem.eql(
        u8,
        &complete.statement.measurements,
        &halted.statement.measurements,
    ));
}

test "a boot counter of zero is never accepted" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture, "the kernel");

    // A device that has never booted cannot be attesting to a boot, and a
    // counter that starts where the verifier's memory starts would let an
    // uninitialized value pass as a first boot.
    const presented = try quote(fixture.device.signer(), &fixture.chain, 0, sample_challenge);
    var seen: Seen = .{};
    try std.testing.expectError(
        error.NotFresh,
        verify(presented, fixture.devicePublicKey(), sample_challenge, &seen),
    );
}
