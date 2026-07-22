//! What a device does when it is interrupted or its storage is damaged.
//!
//! Every other test in this repository asks whether a component behaves
//! correctly when nothing goes wrong with the medium underneath it. This one
//! asks the opposite question, exhaustively: for every byte of a journal, for
//! every stage of an update, for every position in a sealed record, does the
//! system reach a state it can explain?
//!
//! The property being held is not "recovery succeeds". Recovery is often
//! supposed to fail. The property is that there is no input for which the system
//! silently produces wrong state — every outcome is either a correct prefix of
//! what was written, or a refusal that names what went wrong.
//!
//! These sweeps are slow by the standards of a unit test and that is the point.
//! A sampled corruption test finds the corruptions someone thought of.

const std = @import("std");
const core = @import("core");
const storage = @import("storage");

const journal = storage.journal;
const encryption = storage.encryption;
const update = core.update;

const Ed25519 = std.crypto.sign.Ed25519;

/// A journal with a handful of records of differing sizes.
///
/// Varied lengths matter: a corruption that lands on a length field behaves
/// differently from one that lands in a payload, and a journal of uniform
/// records would only ever exercise one of the two.
fn buildJournal(gpa: std.mem.Allocator) !journal.Writer {
    var writer = try journal.Writer.init(gpa);
    errdefer writer.deinit();
    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "running");
    _ = try writer.append(.capability_issued, 2, .fromSeconds(1_001), "");
    _ = try writer.append(.effect_claimed, 3, .fromSeconds(1_002), "a longer payload here");
    _ = try writer.append(.effect_settled, 4, .fromSeconds(1_003), "ok");
    return writer;
}

const Applied = struct {
    sequences: std.ArrayList(u64) = .empty,
    gpa: std.mem.Allocator,

    fn record(applied: *Applied, entry: journal.Record) anyerror!void {
        try applied.sequences.append(applied.gpa, entry.sequence);
    }

    fn deinit(applied: *Applied) void {
        applied.sequences.deinit(applied.gpa);
    }

    /// Whether what was applied is a prefix of what was written: 1, 2, 3, …
    ///
    /// Any other shape means recovery either skipped a record or applied one out
    /// of order, and both are worse than stopping.
    fn isPrefix(applied: Applied) bool {
        for (applied.sequences.items, 1..) |sequence, expected| {
            if (sequence != expected) return false;
        }
        return true;
    }
};

test "a journal truncated at every length recovers a prefix or refuses" {
    const gpa = std.testing.allocator;
    var writer = try buildJournal(gpa);
    defer writer.deinit();
    const complete = writer.written();

    for (0..complete.len + 1) |length| {
        var applied: Applied = .{ .gpa = gpa };
        defer applied.deinit();

        const recovery = journal.replay(
            gpa,
            complete[0..length],
            &applied,
            Applied.record,
        ) catch |failure| {
            // Only allocation can fail here; a damaged journal is a value, not
            // an error, because recovery has to report what it salvaged.
            return failure;
        };

        try std.testing.expect(applied.isPrefix());
        try std.testing.expectEqual(applied.sequences.items.len, recovery.applied);

        // A truncation is never silently clean unless it landed exactly on a
        // record boundary.
        if (recovery.wasClean()) {
            try std.testing.expectEqual(length, recovery.intact_through);
        } else {
            try std.testing.expect(recovery.intact_through <= length);
        }
    }
}

test "a journal with any single byte flipped recovers a prefix or refuses" {
    const gpa = std.testing.allocator;
    var writer = try buildJournal(gpa);
    defer writer.deinit();

    const damaged = try gpa.dupe(u8, writer.written());
    defer gpa.free(damaged);
    const original = try gpa.dupe(u8, writer.written());
    defer gpa.free(original);

    for (0..original.len) |position| {
        // The high bit, so the change is never a no-op on any field width.
        damaged[position] = original[position] ^ 0x80;
        defer damaged[position] = original[position];

        var applied: Applied = .{ .gpa = gpa };
        defer applied.deinit();
        const recovery = try journal.replay(gpa, damaged, &applied, Applied.record);

        try std.testing.expect(applied.isPrefix());
        try std.testing.expect(recovery.intact_through <= damaged.len);

        // A flip inside the reserved header field changes nothing a reader
        // consults, so it is legitimately clean. Every other position falls
        // inside a record and must be caught.
        const in_reserved_header = position >= 6 and position < journal.header_bytes;
        if (!in_reserved_header) {
            try std.testing.expect(!recovery.wasClean());
        }
    }
}

test "no corruption makes recovery apply more than was written" {
    const gpa = std.testing.allocator;
    var writer = try buildJournal(gpa);
    defer writer.deinit();

    const damaged = try gpa.dupe(u8, writer.written());
    defer gpa.free(damaged);
    const original = try gpa.dupe(u8, writer.written());
    defer gpa.free(original);

    // Four records were written. A corruption that produced a fifth would mean
    // a damaged journal inventing state, which is worse than losing it.
    for (0..original.len) |position| {
        for ([_]u8{ 0x00, 0xff }) |replacement| {
            damaged[position] = replacement;
            defer damaged[position] = original[position];

            var applied: Applied = .{ .gpa = gpa };
            defer applied.deinit();
            const recovery = try journal.replay(gpa, damaged, &applied, Applied.record);

            try std.testing.expect(recovery.applied <= 4);
            try std.testing.expect(applied.isPrefix());
        }
    }
}

test "reopening after any truncation leaves a journal that replays cleanly" {
    const gpa = std.testing.allocator;
    var writer = try buildJournal(gpa);
    defer writer.deinit();
    const complete = writer.written();

    // The restart path: whatever the crash left behind, what the device keeps
    // must be something it can read back without stopping. A recovery that
    // leaves the journal unreadable has not recovered anything.
    for (journal.header_bytes..complete.len + 1) |length| {
        var reopened = journal.Writer.recover(gpa, complete[0..length]) catch |failure| {
            try std.testing.expectEqual(journal.Error.TornWrite, failure);
            continue;
        };
        defer reopened.writer.deinit();

        var applied: Applied = .{ .gpa = gpa };
        defer applied.deinit();
        const recovery = try journal.replay(
            gpa,
            reopened.writer.written(),
            &applied,
            Applied.record,
        );
        try std.testing.expect(recovery.wasClean());
        try std.testing.expect(applied.isPrefix());
    }
}

test "appending after a recovery leaves no gap for a later replay to stop at" {
    const gpa = std.testing.allocator;
    var writer = try buildJournal(gpa);
    defer writer.deinit();
    const complete = writer.written();

    for (journal.header_bytes..complete.len + 1) |length| {
        var reopened = journal.Writer.recover(gpa, complete[0..length]) catch continue;
        defer reopened.writer.deinit();

        _ = try reopened.writer.append(.task_transition, 99, .fromSeconds(2_000), "after");

        var applied: Applied = .{ .gpa = gpa };
        defer applied.deinit();
        const recovery = try journal.replay(
            gpa,
            reopened.writer.written(),
            &applied,
            Applied.record,
        );

        // The record written after the crash is reached, every time. A sequence
        // that resumed from the wrong number would strand it behind a gap.
        try std.testing.expect(recovery.wasClean());
        try std.testing.expect(applied.isPrefix());
        try std.testing.expect(applied.sequences.items.len >= 1);
    }
}

test "replaying a recovered journal twice reaches the same state" {
    const gpa = std.testing.allocator;
    var writer = try buildJournal(gpa);
    defer writer.deinit();

    var first: Applied = .{ .gpa = gpa };
    defer first.deinit();
    _ = try journal.replay(gpa, writer.written(), &first, Applied.record);

    var second: Applied = .{ .gpa = gpa };
    defer second.deinit();
    _ = try journal.replay(gpa, writer.written(), &second, Applied.record);

    // Recovery may run more than once — a device can crash while recovering.
    try std.testing.expectEqualSlices(u64, first.sequences.items, second.sequences.items);
}

test "a sealed record with any single byte flipped never opens" {
    const gpa = std.testing.allocator;
    const root_key = "a root key held by the secure element";
    var keys: encryption.StoreKeys = .derive(root_key, .task_state, @splat(3), 1);

    var sealed_buffer: [256]u8 = undefined;
    const sealed = try keys.seal("the contents of a record", &sealed_buffer);

    const damaged = try gpa.dupe(u8, sealed.payload);
    defer gpa.free(damaged);
    const original = try gpa.dupe(u8, sealed.payload);
    defer gpa.free(original);

    var opened_buffer: [256]u8 = undefined;
    for (0..original.len) |position| {
        damaged[position] = original[position] ^ 0x80;
        defer damaged[position] = original[position];

        // Authenticated encryption: damage anywhere is a refusal, never a
        // shorter or altered plaintext handed back as though it were fine.
        try std.testing.expectError(error.IntegrityFailure, keys.open(.{
            .generation = sealed.generation,
            .sequence = sealed.sequence,
            .payload = damaged,
        }, &opened_buffer));
    }
}

test "a sealed record truncated at any length never opens" {
    const root_key = "a root key held by the secure element";
    var keys: encryption.StoreKeys = .derive(root_key, .task_state, @splat(4), 1);

    var sealed_buffer: [256]u8 = undefined;
    const sealed = try keys.seal("the contents of a record", &sealed_buffer);

    var opened_buffer: [256]u8 = undefined;
    for (0..sealed.payload.len) |length| {
        const result = keys.open(.{
            .generation = sealed.generation,
            .sequence = sealed.sequence,
            .payload = sealed.payload[0..length],
        }, &opened_buffer);
        try std.testing.expect(std.meta.isError(result));
    }
}

/// A device that crashes at a chosen point in an update.
const UpdateFixture = struct {
    const device_class = "reference";
    const running: update.Version = .{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .security_generation = 1,
    };

    manual: core.time.ManualClock,
    key_pair: Ed25519.KeyPair,
    updater: update.Updater,

    fn init(fixture: *UpdateFixture) !void {
        fixture.* = .{
            .manual = .init(.fromSeconds(1_000)),
            .key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(77)),
            .updater = undefined,
        };

        var digest: [update.digest_bytes]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("the running system image", &digest, .{});

        fixture.updater = .init(
            fixture.manual.clock(),
            fixture.key_pair.public_key.toBytes(),
            device_class,
            running,
            digest,
        );
    }

    fn image(fixture: *UpdateFixture, contents: []const u8, minor: u32) !update.Image {
        const version: update.Version = .{
            .major = 1,
            .minor = minor,
            .patch = 0,
            .security_generation = 1,
        };
        var digest: [update.digest_bytes]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
        const signature = try fixture.key_pair.sign(&digest, null);
        return update.Image.ofContents(contents, version, device_class, signature.toBytes());
    }
};

test "an update interrupted at any stage leaves a device that can still boot" {
    // The property that matters to an owner: whatever moment the power is cut,
    // the device comes back. Not necessarily updated — but never bricked.
    const steps = 6;
    for (0..steps) |crash_after| {
        var fixture: UpdateFixture = undefined;
        try UpdateFixture.init(&fixture);

        const contents = "the next system image";
        const image = try fixture.image(contents, 1);

        interrupted: {
            if (crash_after == 0) break :interrupted;
            _ = try fixture.updater.stage(image, contents);
            if (crash_after == 1) break :interrupted;
            try fixture.updater.finishStaging(image, contents);
            if (crash_after == 2) break :interrupted;
            try fixture.updater.selectForNextBoot();
            if (crash_after == 3) break :interrupted;
            try fixture.updater.confirmBoot();
            if (crash_after == 4) break :interrupted;
        }

        try std.testing.expect(fixture.updater.hasBootableSlot());
    }
}

test "an update interrupted before it commits leaves the running system selected" {
    var fixture: UpdateFixture = undefined;
    try UpdateFixture.init(&fixture);

    const running = fixture.updater.nextBootSlot();
    const contents = "the next system image";
    const image = try fixture.image(contents, 1);

    _ = try fixture.updater.stage(image, contents);
    try fixture.updater.finishStaging(image, contents);

    // Staged but not selected. A crash here must not have moved the device onto
    // an image nobody decided to boot.
    try std.testing.expectEqual(running, fixture.updater.nextBootSlot());
}

test "a staged image whose contents were damaged is refused" {
    var fixture: UpdateFixture = undefined;
    try UpdateFixture.init(&fixture);

    const contents = "the next system image";
    const image = try fixture.image(contents, 1);
    _ = try fixture.updater.stage(image, contents);

    // Storage damaged the image between staging and the check that precedes
    // commitment. Committing anyway is how a device bricks itself.
    try std.testing.expectError(
        error.IntegrityFailure,
        fixture.updater.finishStaging(image, "the next system imagX"),
    );
    try std.testing.expect(fixture.updater.hasBootableSlot());
}

test "a device that fails to boot the new image returns to the one that worked" {
    var fixture: UpdateFixture = undefined;
    try UpdateFixture.init(&fixture);

    const before = fixture.updater.runningVersion().?;
    const contents = "the next system image";
    const image = try fixture.image(contents, 1);

    _ = try fixture.updater.stage(image, contents);
    try fixture.updater.finishStaging(image, contents);
    try fixture.updater.selectForNextBoot();

    // Repeated failures, as a device that hangs on start would produce.
    for (0..update.max_boot_attempts) |_| {
        fixture.updater.reportBootFailure() catch break;
    }

    try std.testing.expect(fixture.updater.hasBootableSlot());
    const after = fixture.updater.runningVersion().?;
    try std.testing.expectEqual(before.minor, after.minor);
}
