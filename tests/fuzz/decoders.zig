//! Randomized testing of every decoder that reads untrusted bytes.
//!
//! A decoder is the first thing an attacker reaches. These tests feed each one
//! bytes it did not produce — random, mutated, truncated, and structurally
//! plausible — and assert the only permitted outcomes: a correct value, or a
//! typed error. Never a crash, never a read past the input, never a hang.
//!
//! The generator is seeded deterministically, so a failure reproduces exactly
//! from the seed reported alongside it. That matters more than raw coverage: a
//! finding nobody can reproduce is a finding nobody fixes.
//!
//! This runs on every build. The Zig fuzzer explores far deeper and is wired to
//! `zig build fuzz`; it is not a substitute for these, and these are not a
//! substitute for it.

const std = @import("std");
const core = @import("core");
const ipc = @import("ipc");
const storage = @import("storage");
const session = @import("session");

const envelope = ipc.envelope;
const wire = ipc.wire;
const journal = storage.journal;
const encryption = storage.encryption;
const transport = session.transport;
const package_model = core.package;

/// How many inputs each decoder sees per test.
///
/// Enough to exercise the paths that matter while keeping the suite fast enough
/// that nobody is tempted to skip it.
const iterations: usize = 4_000;

/// The seed every run starts from. A failure reports it so the case reproduces.
const base_seed: u64 = 0x5eed_0f_c0de;

/// Bounded input sizes. Beyond this the decoders refuse by length, which is
/// already covered by their own tests; the interesting cases are near the
/// boundaries of what they accept.
const max_generated_bytes: usize = 512;

fn generator(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

/// Fills `buffer` with random bytes and returns a random-length prefix.
fn randomInput(random: std.Random, buffer: []u8) []u8 {
    const length = random.intRangeAtMost(usize, 0, buffer.len);
    random.bytes(buffer[0..length]);
    return buffer[0..length];
}

test "the message envelope decoder survives arbitrary bytes" {
    var prng = generator(base_seed);
    const random = prng.random();
    var buffer: [max_generated_bytes]u8 = undefined;

    for (0..iterations) |index| {
        const input = randomInput(random, &buffer);
        // Either it decodes, or it reports why it did not. Both are fine; a
        // third outcome is a defect.
        if (envelope.decode(input)) |decoded| {
            // Anything it returns must point inside the input it was given.
            try expectWithin(decoded.method, input);
            try expectWithin(decoded.payload, input);
            _ = decoded.hasExpired(0);
        } else |failure| {
            try expectEnvelopeError(failure, index);
        }
    }
}

test "the message envelope decoder survives mutations of valid messages" {
    var prng = generator(base_seed +% 1);
    const random = prng.random();

    var encoded_buffer: [envelope.max_message_bytes]u8 = undefined;
    const valid = try envelope.encode(.{
        .version = envelope.current_version,
        .kind = .request,
        .correlation = 7,
        .idempotency_key = 0x0f0e0d0c0b0a09080706050403020100,
        .principal = 0x1111,
        .task = 0x2222,
        .capability = 0x3333,
        .deadline_nanoseconds = 0,
        .method = "calendar.read",
        .payload = "a request body",
    }, &encoded_buffer);

    var mutated: [envelope.max_message_bytes]u8 = undefined;

    for (0..iterations) |index| {
        @memcpy(mutated[0..valid.len], valid);
        // A valid message with a few bytes changed reaches deeper into the
        // decoder than random noise does.
        const mutations = random.intRangeAtMost(usize, 1, 6);
        for (0..mutations) |_| {
            const position = random.uintLessThan(usize, valid.len);
            mutated[position] = random.int(u8);
        }
        const length = random.intRangeAtMost(usize, 1, valid.len);

        if (envelope.decode(mutated[0..length])) |decoded| {
            try expectWithin(decoded.method, mutated[0..length]);
            try expectWithin(decoded.payload, mutated[0..length]);
        } else |failure| {
            try expectEnvelopeError(failure, index);
        }
    }
}

test "the journal reader survives arbitrary bytes" {
    const gpa = std.testing.allocator;
    var prng = generator(base_seed +% 2);
    const random = prng.random();
    var buffer: [max_generated_bytes]u8 = undefined;

    for (0..iterations) |_| {
        const input = randomInput(random, &buffer);

        var counter: Counter = .{};
        const recovery = journal.replay(gpa, input, &counter, Counter.count) catch |failure| {
            // Allocation failure is the only error replay itself may raise.
            try std.testing.expectEqual(error.OutOfMemory, failure);
            continue;
        };

        // Recovery always terminates with a bounded, coherent result.
        try std.testing.expect(recovery.intact_through <= input.len);
        try std.testing.expect(counter.applied == recovery.applied);
    }
}

test "the journal reader survives mutations of a valid journal" {
    const gpa = std.testing.allocator;
    var prng = generator(base_seed +% 3);
    const random = prng.random();

    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();
    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "running");
    _ = try writer.append(.effect_claimed, 2, .fromSeconds(1_001), "send");
    _ = try writer.append(.audit_appended, 3, .fromSeconds(1_002), "recorded");

    const valid = writer.written();
    const mutated = try gpa.alloc(u8, valid.len);
    defer gpa.free(mutated);

    for (0..iterations) |_| {
        @memcpy(mutated, valid);
        const mutations = random.intRangeAtMost(usize, 1, 4);
        for (0..mutations) |_| {
            mutated[random.uintLessThan(usize, valid.len)] = random.int(u8);
        }
        const length = random.intRangeAtMost(usize, 0, valid.len);

        var counter: Counter = .{};
        const recovery = journal.replay(gpa, mutated[0..length], &counter, Counter.count) catch |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            continue;
        };
        try std.testing.expect(recovery.intact_through <= length);
    }
}

test "the wire reader never reads past the input it was given" {
    var prng = generator(base_seed +% 4);
    const random = prng.random();
    var buffer: [max_generated_bytes]u8 = undefined;

    for (0..iterations) |_| {
        const input = randomInput(random, &buffer);
        var reader: wire.Reader = .init(input);

        // Drive the reader with a random sequence of reads until it refuses.
        var operations: usize = 0;
        while (operations < 32) : (operations += 1) {
            const choice = random.uintLessThan(u8, 7);
            const outcome = switch (choice) {
                0 => blk: {
                    _ = reader.readU8() catch break;
                    break :blk {};
                },
                1 => blk: {
                    _ = reader.readU16() catch break;
                    break :blk {};
                },
                2 => blk: {
                    _ = reader.readU32() catch break;
                    break :blk {};
                },
                3 => blk: {
                    _ = reader.readU64() catch break;
                    break :blk {};
                },
                4 => blk: {
                    _ = reader.readU128() catch break;
                    break :blk {};
                },
                5 => blk: {
                    const bytes = reader.readBytes(max_generated_bytes) catch break;
                    try expectWithin(bytes, input);
                    break :blk {};
                },
                else => blk: {
                    reader.skipUnknown(max_generated_bytes) catch break;
                    break :blk {};
                },
            };
            _ = outcome;
            // The position never passes the end, whatever sequence was chosen.
            try std.testing.expect(reader.position <= input.len);
        }
    }
}

test "the transport record layer survives arbitrary bytes" {
    var prng = generator(base_seed +% 5);
    const random = prng.random();

    const initiator_seed: [std.crypto.dh.X25519.seed_length]u8 = @splat(51);
    const responder_seed: [std.crypto.dh.X25519.seed_length]u8 = @splat(52);
    const initiator_pair = try transport.KeyPair.generateDeterministic(initiator_seed);
    const responder_pair = try transport.KeyPair.generateDeterministic(responder_seed);

    var receiving = try transport.Session.establish(
        responder_pair,
        initiator_pair.publicKey(),
        .{ .value = 2 },
        .{ .value = 1 },
        .responder,
    );
    defer receiving.deinit();

    var buffer: [max_generated_bytes]u8 = undefined;
    var opened: [max_generated_bytes]u8 = undefined;

    for (0..iterations) |_| {
        const input = randomInput(random, &buffer);
        const sequence = random.int(u64);

        // Forged records must never authenticate, and must never crash the
        // receiver on the way to being refused. Which refusal it is depends on
        // the length and sequence drawn; succeeding is the only wrong answer.
        if (receiving.open(.{ .sequence = sequence, .payload = input }, &opened)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "the sealed-record layer survives arbitrary bytes" {
    var prng = generator(base_seed +% 6);
    const random = prng.random();

    const salt: [encryption.salt_bytes]u8 = @splat(13);
    var keys: encryption.StoreKeys = .derive("a device root key", .task_state, salt, 1);
    defer keys.deinit();

    var buffer: [max_generated_bytes]u8 = undefined;
    var opened: [max_generated_bytes]u8 = undefined;

    for (0..iterations) |_| {
        const input = randomInput(random, &buffer);

        const outcome = keys.open(.{
            .generation = random.int(u32),
            .sequence = random.int(u64),
            .payload = input,
        }, &opened);

        // Forged state must never open. Which refusal it is depends on the
        // generation drawn, and all of them are refusals.
        if (outcome) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "package verification survives arbitrary contents and signatures" {
    const gpa = std.testing.allocator;
    var prng = generator(base_seed +% 7);
    const random = prng.random();

    var manual: core.time.ManualClock = .init(.fromSeconds(1_000));
    var installer: package_model.Installer = .init(gpa, manual.clock());
    defer installer.deinit();

    const seed: [std.crypto.sign.Ed25519.KeyPair.seed_length]u8 = @splat(17);
    const key_pair: std.crypto.sign.Ed25519.KeyPair = try .generateDeterministic(seed);
    try installer.trustPublisher(.{
        .name = "reference publisher",
        .key = key_pair.public_key.toBytes(),
    });

    var contents: [max_generated_bytes]u8 = undefined;
    var operations: core.capability.OperationSet = .initEmpty();
    operations.insert(.execute);

    for (0..iterations) |_| {
        const bytes = randomInput(random, &contents);

        var signature: [package_model.signature_bytes]u8 = undefined;
        random.bytes(&signature);

        var digest: [package_model.digest_bytes]u8 = undefined;
        random.bytes(&digest);

        const package: package_model.Package = .{
            // A random identity that will not match the contents, exercising
            // the path that must reject before any key is consulted.
            .identity = .{ .digest = digest },
            .manifest = .{
                .name = "component",
                .publisher = "reference publisher",
                .version = .{ .major = 1, .minor = 0, .patch = 0 },
                .declared_capabilities = &.{.{
                    .resource_kind = "compute",
                    .operations = operations,
                    .justification = "run",
                }},
            },
            .contents = bytes,
            .signature = signature,
        };

        // A forged package must never verify.
        if (installer.verify(package)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "a randomly generated valid envelope always round-trips" {
    var prng = generator(base_seed +% 8);
    const random = prng.random();

    var encoded_buffer: [envelope.max_message_bytes]u8 = undefined;
    var method_buffer: [envelope.max_method_bytes]u8 = undefined;
    var payload_buffer: [1024]u8 = undefined;

    for (0..iterations) |_| {
        const method_len = random.intRangeAtMost(usize, 0, method_buffer.len);
        random.bytes(method_buffer[0..method_len]);
        const payload_len = random.intRangeAtMost(usize, 0, payload_buffer.len);
        random.bytes(payload_buffer[0..payload_len]);

        const kinds = [_]envelope.Kind{ .request, .response, .fault, .cancel };
        const kind = kinds[random.uintLessThan(usize, kinds.len)];

        const original: envelope.Envelope = .{
            .version = envelope.current_version,
            .kind = kind,
            .correlation = random.int(u64),
            // A request must carry a key; anything else may or may not.
            .idempotency_key = if (kind == .request)
                random.intRangeAtMost(u128, 1, std.math.maxInt(u128))
            else
                random.int(u128),
            .principal = random.int(u128),
            .task = random.int(u128),
            .capability = random.int(u128),
            .deadline_nanoseconds = random.int(i64),
            .method = method_buffer[0..method_len],
            .payload = payload_buffer[0..payload_len],
        };

        const encoded = try envelope.encode(original, &encoded_buffer);
        const decoded = try envelope.decode(encoded);

        // Whatever was encoded comes back unchanged, for every field.
        try std.testing.expectEqual(original.kind, decoded.kind);
        try std.testing.expectEqual(original.correlation, decoded.correlation);
        try std.testing.expectEqual(original.idempotency_key, decoded.idempotency_key);
        try std.testing.expectEqual(original.principal, decoded.principal);
        try std.testing.expectEqual(original.task, decoded.task);
        try std.testing.expectEqual(original.capability, decoded.capability);
        try std.testing.expectEqual(
            original.deadline_nanoseconds,
            decoded.deadline_nanoseconds,
        );
        try std.testing.expectEqualSlices(u8, original.method, decoded.method);
        try std.testing.expectEqualSlices(u8, original.payload, decoded.payload);
    }
}

test "a randomly generated journal always replays to what was written" {
    const gpa = std.testing.allocator;
    var prng = generator(base_seed +% 9);
    const random = prng.random();

    for (0..256) |_| {
        var writer = try journal.Writer.init(gpa);
        defer writer.deinit();

        const count = random.intRangeAtMost(usize, 0, 16);
        var payload: [128]u8 = undefined;

        for (0..count) |index| {
            const kinds = std.enums.values(journal.RecordKind);
            const kind = kinds[random.uintLessThan(usize, kinds.len)];
            const length = random.intRangeAtMost(usize, 0, payload.len);
            random.bytes(payload[0..length]);
            _ = try writer.append(
                kind,
                @intCast(index + 1),
                .fromSeconds(1_000),
                payload[0..length],
            );
        }

        var counter: Counter = .{};
        const recovery = try journal.replay(gpa, writer.written(), &counter, Counter.count);

        try std.testing.expect(recovery.wasClean());
        try std.testing.expectEqual(count, recovery.applied);
    }
}

const Counter = struct {
    applied: usize = 0,

    fn count(counter: *Counter, record: journal.Record) anyerror!void {
        _ = record;
        counter.applied += 1;
    }
};

/// Confirms a returned slice borrows from the input rather than pointing
/// somewhere else. A decoder returning memory outside what it was given is the
/// defect these tests exist to catch.
fn expectWithin(slice: []const u8, input: []const u8) !void {
    if (slice.len == 0) return;
    if (input.len == 0) return error.TestUnexpectedResult;

    const slice_start = @intFromPtr(slice.ptr);
    const input_start = @intFromPtr(input.ptr);
    try std.testing.expect(slice_start >= input_start);
    try std.testing.expect(slice_start + slice.len <= input_start + input.len);
}

/// The envelope decoder's failures are a closed set. An error outside it means
/// something is escaping that the caller cannot be expected to handle.
fn expectEnvelopeError(failure: anyerror, index: usize) !void {
    switch (failure) {
        error.Truncated,
        error.LengthExceeded,
        error.ValueOutOfRange,
        error.BufferTooSmall,
        error.ProtocolMismatch,
        error.IncompatibleVersion,
        error.UnknownEnumeration,
        error.MissingIdempotencyKey,
        error.TrailingBytes,
        => {},
        else => {
            std.debug.print(
                "unexpected decoder error {t} at iteration {d}; reproduce with seed {x}\n",
                .{ failure, index, base_seed },
            );
            return error.TestUnexpectedResult;
        },
    }
}
