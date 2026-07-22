//! What was actually loaded during a boot.
//!
//! Verification and measurement answer different questions. Verification asks
//! whether a stage is one the device accepts. Measurement records which one ran.
//! A device that only verifies can say it booted something acceptable; one that
//! measures can say which, and that difference is the whole value of an
//! attestation.
//!
//! The log is fixed-size and written before there is an allocator to grow it
//! with, so it refuses further entries rather than expanding.

const std = @import("std");
const core = @import("core");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_bytes = Sha256.digest_length;

/// How many measurements the log holds: one per stage, with room for a recovery
/// path taken instead of the normal one.
pub const capacity: usize = 8;

pub const Error = error{
    /// The log is full. Recorded rather than dropped silently, because a
    /// measurement that is missing and a measurement that is absent look the
    /// same to a verifier afterwards.
    LogFull,
};

/// One entry.
pub const Measurement = struct {
    /// Which stage this describes. Stored as its ordinal so this module does
    /// not depend on the chain that fills it in.
    stage: u8,
    /// What was actually loaded.
    digest: [digest_bytes]u8,
    /// The version the stage declared.
    version: u32,
    measured_at: core.time.Timestamp,
};

/// The measurements taken this boot, in order.
pub const Log = struct {
    entries: [capacity]Measurement = undefined,
    recorded: usize = 0,

    pub fn record(log: *Log, entry: Measurement) Error!void {
        if (log.recorded == capacity) return error.LogFull;
        log.entries[log.recorded] = entry;
        log.recorded += 1;
    }

    pub fn taken(log: *const Log) []const Measurement {
        return log.entries[0..log.recorded];
    }

    /// A single value summarizing everything measured.
    ///
    /// Order-dependent, so two boots that loaded the same stages in a different
    /// order produce different summaries. Extending rather than combining
    /// means a later entry cannot cancel an earlier one out.
    pub fn summary(log: *const Log) [digest_bytes]u8 {
        var hash: Sha256 = .init(.{});
        for (log.taken()) |entry| {
            hash.update(&[_]u8{entry.stage});
            hash.update(&entry.digest);
            var version: [4]u8 = undefined;
            std.mem.writeInt(u32, &version, entry.version, .little);
            hash.update(&version);
        }
        var digest: [digest_bytes]u8 = undefined;
        hash.final(&digest);
        return digest;
    }
};

/// Measures a loaded image.
pub fn digestOf(contents: []const u8) [digest_bytes]u8 {
    var digest: [digest_bytes]u8 = undefined;
    Sha256.hash(contents, &digest, .{});
    return digest;
}

fn entryAt(stage: u8, contents: []const u8, version: u32) Measurement {
    return .{
        .stage = stage,
        .digest = digestOf(contents),
        .version = version,
        .measured_at = .fromSeconds(1_000),
    };
}

test "the log records what was loaded, in order" {
    var log: Log = .{};
    try log.record(entryAt(1, "the bootloader", 1));
    try log.record(entryAt(2, "the kernel", 1));

    const taken = log.taken();
    try std.testing.expectEqual(@as(usize, 2), taken.len);
    try std.testing.expectEqual(@as(u8, 1), taken[0].stage);
    try std.testing.expectEqualSlices(u8, &digestOf("the kernel"), &taken[1].digest);
}

test "the same boot summarizes to the same value" {
    var first: Log = .{};
    var second: Log = .{};
    for ([_]*Log{ &first, &second }) |log| {
        try log.record(entryAt(1, "the bootloader", 1));
        try log.record(entryAt(2, "the kernel", 1));
    }

    // An attestation is only meaningful if the same system attests the same
    // value twice.
    try std.testing.expectEqualSlices(u8, &first.summary(), &second.summary());
}

test "a different stage produces a different summary" {
    var first: Log = .{};
    try first.record(entryAt(1, "the bootloader", 1));
    try first.record(entryAt(2, "the kernel", 1));

    var second: Log = .{};
    try second.record(entryAt(1, "the bootloader", 1));
    try second.record(entryAt(2, "a different kernel", 1));

    try std.testing.expect(!std.mem.eql(u8, &first.summary(), &second.summary()));
}

test "a different version produces a different summary" {
    var first: Log = .{};
    try first.record(entryAt(1, "the bootloader", 1));

    var second: Log = .{};
    try second.record(entryAt(1, "the bootloader", 2));

    // Identical contents at a different declared version are still a different
    // boot, and a verifier must be able to tell.
    try std.testing.expect(!std.mem.eql(u8, &first.summary(), &second.summary()));
}

test "order changes the summary" {
    var forward: Log = .{};
    try forward.record(entryAt(1, "first", 1));
    try forward.record(entryAt(2, "second", 1));

    var reversed: Log = .{};
    try reversed.record(entryAt(2, "second", 1));
    try reversed.record(entryAt(1, "first", 1));

    try std.testing.expect(!std.mem.eql(u8, &forward.summary(), &reversed.summary()));
}

test "an empty log still summarizes" {
    const empty: Log = .{};
    // A boot that measured nothing must produce a value a verifier can reject,
    // not an absent one it might treat as trivially acceptable.
    var populated: Log = .{};
    try populated.record(entryAt(1, "the bootloader", 1));
    try std.testing.expect(!std.mem.eql(u8, &empty.summary(), &populated.summary()));
}

test "the log refuses rather than expanding" {
    var log: Log = .{};
    for (0..capacity) |index| {
        try log.record(entryAt(@intCast(index), "a stage", 1));
    }
    try std.testing.expectError(error.LogFull, log.record(entryAt(0, "one more", 1)));
    try std.testing.expectEqual(capacity, log.taken().len);
}
