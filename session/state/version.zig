//! Deciding whether a state update is accepted, so the instance's state moves only forward and a
//! stale endpoint cannot overwrite newer state with older.
//!
//! An instance is presented on several endpoints, each holding a cached copy of its state, and each
//! able to propose changes. The hazard is the lost update: an endpoint that fell behind, then sends a
//! change computed against the state it last saw, silently clobbering everything committed in the
//! meantime. The instance guards against this by versioning state monotonically — every committed
//! change advances a version counter — and accepting a proposed update only when it is built on the
//! current version. An update whose base version is behind the current one is rejected as stale; the
//! endpoint must catch up to the current state and reapply. An update built on the current version is
//! accepted and advances it by one, so the counter never moves backward and never skips. Requiring
//! each accepted update to build on the present state is what makes concurrent editing safe: the
//! order is total, and no endpoint's staleness can erase another's committed work.
//!
//! This module stores no state. It decides whether an update is accepted and what the version
//! becomes, from the current version and the update's base version, as pure functions.

const std = @import("std");

/// A proposed state update, tagged with the version it was computed against.
pub const Update = struct {
    /// The version of instance state this update was built on.
    base_version: u64,
};

/// The result of applying an update.
pub const Result = union(enum) {
    /// The update was accepted; the instance state is now at this version.
    accepted: u64,
    /// The update was rejected as stale; the version is unchanged and the endpoint must catch up.
    stale,
};

/// Whether an update built on a base version is current with respect to the instance.
fn isCurrent(current_version: u64, base_version: u64) bool {
    return base_version == current_version;
}

/// Decides whether an update is accepted against the current instance version.
///
/// The update is accepted only when its base version equals the current version — it was computed
/// against the present state. An accepted update advances the version by one. An update built on any
/// earlier version is stale and rejected without changing the version, so state never regresses and
/// no committed change is lost to a late writer.
pub fn apply(current_version: u64, update: Update) Result {
    if (!isCurrent(current_version, update.base_version)) return .stale;
    return .{ .accepted = current_version + 1 };
}

test "an update built on the current version is accepted and advances it" {
    try std.testing.expectEqual(Result{ .accepted = 6 }, apply(5, .{ .base_version = 5 }));
}

test "an update built on an older version is stale" {
    try std.testing.expectEqual(Result.stale, apply(5, .{ .base_version = 3 }));
}

test "the version never moves backward, swept" {
    // The monotonicity property: after any apply, the resulting version is at least the current one,
    // and it only ever increases on acceptance.
    const current: u64 = 10;
    var base: u64 = 6;
    while (base <= 14) : (base += 1) {
        switch (apply(current, .{ .base_version = base })) {
            .accepted => |version| {
                try std.testing.expectEqual(current, base); // Only the current base is accepted.
                try std.testing.expect(version > current);
            },
            .stale => try std.testing.expect(base != current),
        }
    }
}
