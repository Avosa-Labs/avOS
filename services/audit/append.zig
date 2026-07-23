//! Deciding whether an audit entry may be appended, enforcing that the log only ever
//! grows in order and is chained so tampering shows, because an audit trail that can
//! be edited is no audit trail at all.
//!
//! An audit log is the record an investigation trusts, and its value rests entirely
//! on two properties: it is append-only, and it is tamper-evident. Append-only means
//! entries are added in a strict sequence and nothing is ever deleted or rewritten —
//! there is no operation to remove an entry, because the ability to remove one is the
//! ability to erase the evidence of the thing being audited. Tamper-evident means each
//! entry carries the hash of the one before it, so the entries form a chain; altering
//! any past entry changes its hash and breaks the link to the next, and the break is
//! detectable even though the alteration was not prevented. Together they mean the log
//! can be trusted after the fact: an attacker who compromises the device can stop new
//! honest entries, but cannot quietly rewrite the history of what they did.
//!
//! This module stores no log. It decides whether a proposed entry validly extends the
//! chain — the sequence advances by one and the link matches — and verifies a chain's
//! integrity, as pure functions so the append-only, tamper-evident rule lives in one
//! place.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The hash linking one entry to the previous. A fixed-width digest so the chain is
/// uniform.
pub const Link = [Sha256.digest_length]u8;

/// The link value for the first entry, which has no predecessor.
pub const genesis_link: Link = [_]u8{0} ** Sha256.digest_length;

/// One audit entry as it sits in the log.
pub const Entry = struct {
    /// The position in the log, starting at 0 and advancing by exactly one.
    sequence: u64,
    /// The hash of the previous entry, chaining this one to it. `genesis_link` for
    /// the first entry.
    previous_link: Link,
    /// An opaque digest of this entry's own content, used to link the next entry.
    content_digest: Link,
};

/// Computes the link a following entry must carry: the hash of this entry's sequence,
/// previous link, and content digest together, so the chain covers position and
/// order as well as content.
pub fn linkAfter(entry: Entry) Link {
    var hasher = Sha256.init(.{});
    var seq_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_bytes, entry.sequence, .little);
    hasher.update(&seq_bytes);
    hasher.update(&entry.previous_link);
    hasher.update(&entry.content_digest);
    var link: Link = undefined;
    hasher.final(&link);
    return link;
}

/// Why an append was rejected.
pub const Rejection = enum {
    /// The proposed sequence is not exactly one past the last entry.
    sequence_gap,
    /// The proposed previous-link does not match the last entry's computed link, so
    /// the chain would not be continuous.
    broken_link,
};

/// The append decision.
pub const Decision = union(enum) {
    append,
    reject: Rejection,

    pub fn appends(decision: Decision) bool {
        return decision == .append;
    }
};

/// Decides whether a proposed entry validly extends the log after `last`.
///
/// The proposed sequence must be exactly one past the last entry's, so the log never
/// skips a position or reuses one, and the proposed previous-link must equal the link
/// computed from the last entry, so the chain is unbroken. There is deliberately no
/// path that removes or replaces an existing entry: the only valid mutation is this
/// forward extension, which is what makes the log append-only.
pub fn decideAppend(last: Entry, proposed: Entry) Decision {
    if (proposed.sequence != last.sequence + 1) return .{ .reject = .sequence_gap };
    if (!std.mem.eql(u8, &proposed.previous_link, &linkAfter(last))) return .{ .reject = .broken_link };
    return .append;
}

/// The decision for the very first entry, which has no predecessor: its sequence must
/// be zero and its previous-link the genesis value.
pub fn decideFirst(proposed: Entry) Decision {
    if (proposed.sequence != 0) return .{ .reject = .sequence_gap };
    if (!std.mem.eql(u8, &proposed.previous_link, &genesis_link)) return .{ .reject = .broken_link };
    return .append;
}

/// Verifies that a sequence of entries forms an unbroken, correctly ordered chain.
/// Returns the index of the first entry that breaks it, or null if the whole chain is
/// intact — so a verifier learns exactly where tampering occurred.
pub fn verifyChain(entries: []const Entry) ?usize {
    for (entries, 0..) |entry, index| {
        const expected_seq: u64 = index;
        if (entry.sequence != expected_seq) return index;
        const expected_link = if (index == 0) genesis_link else linkAfter(entries[index - 1]);
        if (!std.mem.eql(u8, &entry.previous_link, &expected_link)) return index;
    }
    return null;
}

fn digest(seed: u8) Link {
    var d: Link = undefined;
    Sha256.hash(&[_]u8{seed}, &d, .{});
    return d;
}

fn chainOf(count: usize, buffer: []Entry) []Entry {
    var previous: Link = genesis_link;
    for (0..count) |i| {
        buffer[i] = .{ .sequence = i, .previous_link = previous, .content_digest = digest(@intCast(i + 1)) };
        previous = linkAfter(buffer[i]);
    }
    return buffer[0..count];
}

test "a valid next entry appends" {
    const last: Entry = .{ .sequence = 4, .previous_link = genesis_link, .content_digest = digest(1) };
    const proposed: Entry = .{ .sequence = 5, .previous_link = linkAfter(last), .content_digest = digest(2) };
    try std.testing.expect(decideAppend(last, proposed).appends());
}

test "a sequence gap is rejected" {
    const last: Entry = .{ .sequence = 4, .previous_link = genesis_link, .content_digest = digest(1) };
    // Skips to 6.
    const proposed: Entry = .{ .sequence = 6, .previous_link = linkAfter(last), .content_digest = digest(2) };
    try std.testing.expectEqual(Decision{ .reject = .sequence_gap }, decideAppend(last, proposed));
}

test "a reused sequence is rejected" {
    const last: Entry = .{ .sequence = 4, .previous_link = genesis_link, .content_digest = digest(1) };
    const proposed: Entry = .{ .sequence = 4, .previous_link = linkAfter(last), .content_digest = digest(2) };
    try std.testing.expectEqual(Decision{ .reject = .sequence_gap }, decideAppend(last, proposed));
}

test "a broken link is rejected" {
    const last: Entry = .{ .sequence = 4, .previous_link = genesis_link, .content_digest = digest(1) };
    // Correct sequence but wrong previous-link.
    const proposed: Entry = .{ .sequence = 5, .previous_link = digest(99), .content_digest = digest(2) };
    try std.testing.expectEqual(Decision{ .reject = .broken_link }, decideAppend(last, proposed));
}

test "the first entry must be sequence zero from genesis" {
    try std.testing.expect(decideFirst(.{ .sequence = 0, .previous_link = genesis_link, .content_digest = digest(1) }).appends());
    try std.testing.expectEqual(
        Decision{ .reject = .sequence_gap },
        decideFirst(.{ .sequence = 1, .previous_link = genesis_link, .content_digest = digest(1) }),
    );
}

test "a well-formed chain verifies intact" {
    var buffer: [8]Entry = undefined;
    const chain = chainOf(6, &buffer);
    try std.testing.expectEqual(@as(?usize, null), verifyChain(chain));
}

test "tampering with a past entry breaks the chain at the next link" {
    var buffer: [8]Entry = undefined;
    const chain = chainOf(6, &buffer);
    // Alter entry 2's content after the fact; entry 3's previous-link no longer
    // matches the recomputed link of the altered entry 2.
    buffer[2].content_digest = digest(200);
    const broken_at = verifyChain(chain);
    try std.testing.expectEqual(@as(?usize, 3), broken_at);
}

test "reordering entries is detected as a sequence break" {
    var buffer: [8]Entry = undefined;
    const chain = chainOf(4, &buffer);
    std.mem.swap(Entry, &buffer[1], &buffer[2]);
    try std.testing.expect(verifyChain(chain) != null);
}

test "only a forward extension by one with a matching link ever appends, swept" {
    // The append-only property: across a range of proposed sequences and links, an
    // append is accepted exactly when the sequence advances by one and the link
    // matches.
    const last: Entry = .{ .sequence = 10, .previous_link = genesis_link, .content_digest = digest(1) };
    const good_link = linkAfter(last);
    var seq: u64 = 8;
    while (seq <= 13) : (seq += 1) {
        for ([_]Link{ good_link, digest(77) }) |link| {
            const proposed: Entry = .{ .sequence = seq, .previous_link = link, .content_digest = digest(2) };
            const decision = decideAppend(last, proposed);
            const should_append = seq == last.sequence + 1 and std.mem.eql(u8, &link, &good_link);
            try std.testing.expectEqual(should_append, decision.appends());
        }
    }
}
