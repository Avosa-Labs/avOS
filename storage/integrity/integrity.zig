//! Detecting silent corruption in data at rest, so a store returns correct data or
//! an error, never wrong data believed to be right.
//!
//! Storage media do not fail only by refusing to read; they fail by returning the
//! wrong bytes — a flipped bit from cosmic rays or wear, a misdirected write that
//! landed a good block in the wrong place, a controller returning a stale copy. A
//! store that hands those bytes to the layer above as if they were correct is worse
//! than one that loses them, because the corruption propagates into decisions and
//! backups before anyone notices. The defence is to store a checksum alongside each
//! block and verify it on every read: a block whose contents no longer match its
//! checksum is not returned as data, it is reported as corrupt. And because
//! corruption accumulates silently on blocks that are rarely read, a scrub sweeps
//! the whole store proactively and stops at the first block that fails, so recovery
//! begins from a known-good prefix rather than a guess.
//!
//! This module reads no device. It computes and verifies per-block checksums and
//! decides the outcome of a scrub, as pure functions over block contents, so the
//! "return correct data or an error" guarantee is enforced in one place rather than
//! trusted to each reader.

const std = @import("std");

const Crc = std.hash.crc.Crc32;

/// A block's integrity tag: the checksum stored alongside its contents.
pub const Checksum = u32;

/// Computes the checksum of a block's contents.
///
/// A CRC-32 detects the bit flips, truncations, and misdirected writes that are
/// the common at-rest failures; it is not a cryptographic tag and does not defend
/// against a deliberate forger, which is the integrity layer's job above this, not
/// the medium-corruption job here.
pub fn checksum(contents: []const u8) Checksum {
    return Crc.hash(contents);
}

/// A block as stored: its contents and the checksum recorded when it was written.
pub const Block = struct {
    contents: []const u8,
    recorded: Checksum,
};

/// Whether a block's contents still match the checksum recorded for them.
///
/// This is the read-path gate: a reader calls it before handing bytes up, and a
/// block that fails is reported as corrupt rather than returned. Recomputing from
/// the contents and comparing is what turns silent corruption into a detected
/// error.
pub fn verify(block: Block) bool {
    return checksum(block.contents) == block.recorded;
}

/// Seals contents into a block by recording their checksum, for the write path.
pub fn seal(contents: []const u8) Block {
    return .{ .contents = contents, .recorded = checksum(contents) };
}

/// The result of scrubbing a sequence of blocks.
pub const ScrubResult = union(enum) {
    /// Every block verified. The store is clean.
    clean,
    /// A block failed to verify. The index is the first corrupt block; every block
    /// before it verified, so recovery has a known-good prefix to start from.
    corrupt_at: usize,

    pub fn isClean(result: ScrubResult) bool {
        return result == .clean;
    }
};

/// Scrubs a sequence of blocks, stopping at the first corruption.
///
/// It verifies blocks in order and returns the index of the first that fails,
/// rather than counting all failures, because the point of a scrub is to establish
/// how far the store is known good: everything before the first failure verified,
/// and that prefix is what recovery can trust. A clean sweep means every block
/// matched its checksum.
pub fn scrub(blocks: []const Block) ScrubResult {
    for (blocks, 0..) |block, index| {
        if (!verify(block)) return .{ .corrupt_at = index };
    }
    return .clean;
}

test "sealed contents verify" {
    const block = seal("the quick brown fox");
    try std.testing.expect(verify(block));
}

test "a flipped bit is detected" {
    var bytes = "the quick brown fox".*;
    var block = seal(&bytes);
    // Corrupt one byte after sealing.
    bytes[4] ^= 0x01;
    block.contents = &bytes;
    try std.testing.expect(!verify(block));
}

test "a truncation is detected" {
    const original = "a block of data padded out to some length";
    var block = seal(original);
    // The stored checksum was for the full contents; a short read does not match.
    block.contents = original[0 .. original.len - 1];
    try std.testing.expect(!verify(block));
}

test "a misdirected write is detected as a checksum mismatch" {
    // Reading a different good block where this one should be: its contents are
    // valid but its checksum is not the one recorded here.
    const wrong = seal("some other block that is itself fine");
    const here: Block = .{ .contents = wrong.contents, .recorded = checksum("what belongs here") };
    try std.testing.expect(!verify(here));
}

test "a clean sequence scrubs clean" {
    const blocks = [_]Block{ seal("one"), seal("two"), seal("three") };
    try std.testing.expect(scrub(&blocks).isClean());
}

test "a scrub reports the first corrupt block and its known-good prefix" {
    var third = "three".*;
    var blocks = [_]Block{ seal("one"), seal("two"), seal(&third), seal("four") };
    // Corrupt the third block after sealing.
    third[0] ^= 0x01;
    blocks[2].contents = &third;

    switch (scrub(&blocks)) {
        .corrupt_at => |index| try std.testing.expectEqual(@as(usize, 2), index),
        .clean => return error.TestUnexpectedResult,
    }
}

test "a scrub stops at the first failure, not the last" {
    var second = "two".*;
    var fourth = "four".*;
    var blocks = [_]Block{ seal("one"), seal(&second), seal("three"), seal(&fourth) };
    second[0] ^= 0x01;
    fourth[0] ^= 0x01;
    blocks[1].contents = &second;
    blocks[3].contents = &fourth;
    // Two blocks are corrupt; the scrub reports the earlier one, defining the
    // known-good prefix as blocks 0..1.
    switch (scrub(&blocks)) {
        .corrupt_at => |index| try std.testing.expectEqual(@as(usize, 1), index),
        .clean => return error.TestUnexpectedResult,
    }
}

test "an empty store scrubs clean" {
    try std.testing.expect(scrub(&.{}).isClean());
}

test "the checksum is deterministic and content-sensitive" {
    try std.testing.expectEqual(checksum("data"), checksum("data"));
    try std.testing.expect(checksum("data") != checksum("dat0"));
}

test "every block before a reported corruption genuinely verifies, swept" {
    // The known-good-prefix property: whatever index a scrub reports, all blocks
    // before it pass verification.
    var bad = "corruptible".*;
    var blocks = [_]Block{ seal("a"), seal("b"), seal("c"), seal(&bad), seal("e") };
    bad[0] ^= 0xFF;
    blocks[3].contents = &bad;
    switch (scrub(&blocks)) {
        .corrupt_at => |index| {
            for (blocks[0..index]) |block| try std.testing.expect(verify(block));
        },
        .clean => return error.TestUnexpectedResult,
    }
}
