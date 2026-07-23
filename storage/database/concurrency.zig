//! Deciding whether a transaction may commit against what other transactions have
//! done since it read, so concurrent writers cannot silently overwrite each
//! other's work.
//!
//! When two transactions run at once, each reads some records, decides what to
//! write based on what it read, and commits. If nothing checks for interference, a
//! transaction that read a record, computed a new value from it, and wrote it back
//! will clobber a change another transaction committed to that same record in the
//! meantime — the lost update, where one writer's work simply vanishes and no error
//! is raised. Optimistic concurrency prevents it without locking: a transaction
//! records the version of every record it read, and at commit those versions are
//! checked against the current ones. If any record it based its decision on has
//! changed, the decision was made on stale data and the transaction must abort and
//! retry rather than commit a lost update.
//!
//! This module stores nothing durable. It tracks record versions and decides
//! whether a transaction's read-set is still current at commit, as a pure function
//! over the versions, so the serialization guarantee lives in one checked place
//! rather than in each writer's hope that no one else touched its records.

const std = @import("std");

/// A record key. Opaque to this layer; the store maps it to data.
pub const Key = u64;

/// A record's version, bumped on every committed write. Monotonic, so a higher
/// version always means a later write.
pub const Version = u64;

/// The version a record held when a transaction read it. Comparing this against the
/// record's current version at commit is what detects interference.
pub const ReadVersion = struct {
    key: Key,
    version: Version,
};

/// The current versions of the records a store holds. Small and array-backed here;
/// a real store indexes it, but the commit decision is the same.
pub const VersionMap = struct {
    entries: []const ReadVersion,

    /// The current version of a key, or zero if the key has never been written.
    /// Version zero is the "never existed" sentinel, so a read of a not-yet-created
    /// record records zero and a later creation bumps it to a real version.
    pub fn currentVersion(map: VersionMap, key: Key) Version {
        for (map.entries) |entry| {
            if (entry.key == key) return entry.version;
        }
        return 0;
    }
};

/// The outcome of a commit attempt.
pub const Commit = union(enum) {
    /// The read-set is still current; the transaction may commit.
    commit,
    /// A record the transaction read has changed since; it must abort and retry.
    /// The key names the record that moved, so the caller can report which.
    abort: Key,

    pub fn committed(commit: Commit) bool {
        return commit == .commit;
    }
};

/// Decides whether a transaction may commit, given the records it read and the
/// store's current versions.
///
/// Every record in the read-set is checked: if the version the transaction saw
/// still matches the current version, no one interfered with that record; if it
/// differs, another transaction committed a change the read-set did not account
/// for, and this transaction aborts naming that record. A transaction whose entire
/// read-set is unchanged commits. The first changed record found is enough to
/// abort — one lost-update risk is a conflict — so the check stops there.
pub fn validate(read_set: []const ReadVersion, current: VersionMap) Commit {
    for (read_set) |read| {
        if (current.currentVersion(read.key) != read.version) {
            return .{ .abort = read.key };
        }
    }
    return .commit;
}

const store: VersionMap = .{ .entries = &.{
    .{ .key = 1, .version = 5 },
    .{ .key = 2, .version = 3 },
    .{ .key = 3, .version = 9 },
} };

test "a transaction whose reads are all current commits" {
    const read_set = [_]ReadVersion{
        .{ .key = 1, .version = 5 },
        .{ .key = 2, .version = 3 },
    };
    try std.testing.expect(validate(&read_set, store).committed());
}

test "a transaction that read a since-changed record aborts" {
    // It read key 1 at version 4, but the store is now at 5: someone committed in
    // between.
    const read_set = [_]ReadVersion{.{ .key = 1, .version = 4 }};
    try std.testing.expectEqual(Commit{ .abort = 1 }, validate(&read_set, store));
}

test "the abort names the record that moved" {
    const read_set = [_]ReadVersion{
        .{ .key = 1, .version = 5 }, // current
        .{ .key = 3, .version = 8 }, // stale: store is at 9
    };
    try std.testing.expectEqual(Commit{ .abort = 3 }, validate(&read_set, store));
}

test "reading a not-yet-created record and committing its creation" {
    // A transaction reads key 42 (never written, version 0) and commits as long as
    // no one else created it first.
    const read_set = [_]ReadVersion{.{ .key = 42, .version = 0 }};
    try std.testing.expect(validate(&read_set, store).committed());
}

test "a record created by another transaction since the read aborts the creation" {
    // The transaction saw key 2 as absent (version 0), but it now exists at 3:
    // another transaction created it, so this one aborts rather than overwrite.
    const read_set = [_]ReadVersion{.{ .key = 2, .version = 0 }};
    try std.testing.expectEqual(Commit{ .abort = 2 }, validate(&read_set, store));
}

test "an empty read-set commits: it depended on nothing" {
    try std.testing.expect(validate(&.{}, store).committed());
}

test "a lost update is always caught, swept" {
    // The serialization property: for every record, a read at any version other
    // than the current one aborts, and only the exact current version commits.
    for (store.entries) |entry| {
        var v: Version = 0;
        while (v <= entry.version + 2) : (v += 1) {
            const read_set = [_]ReadVersion{.{ .key = entry.key, .version = v }};
            const result = validate(&read_set, store);
            if (v == entry.version) {
                try std.testing.expect(result.committed());
            } else {
                try std.testing.expectEqual(Commit{ .abort = entry.key }, result);
            }
        }
    }
}

test "the first conflicting record is enough to abort" {
    // Two records are stale; the check aborts on the first in the read-set.
    const read_set = [_]ReadVersion{
        .{ .key = 2, .version = 2 }, // stale
        .{ .key = 3, .version = 8 }, // also stale
    };
    try std.testing.expectEqual(Commit{ .abort = 2 }, validate(&read_set, store));
}
