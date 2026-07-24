//! Ordering the recent-apps list and evicting the oldest when it is full, so the app switcher
//! shows what a person just used and stays bounded.
//!
//! The app switcher is a person's short-term memory of what they were doing: the app they
//! just left should be first, so a quick switch back is one gesture. That means most-recently-
//! used order — every time an app comes to the foreground it moves to the front of the list.
//! The list is also bounded, because an unbounded recents list holds every app ever opened,
//! costs memory to keep warm, and buries the few apps a person actually switches between. So
//! when the list is full and a new app is used, the least-recently-used app is evicted — the
//! one the person is least likely to want back — rather than refusing the new one or growing
//! without limit. Most-recent-first ordering with least-recent eviction is the whole of a
//! switcher that always has the right app at the front and never grows into a junk drawer.
//!
//! This module tracks no apps. It decides an app's new position when it is used and which app
//! is evicted when the list overflows, as pure functions over the recents list.

const std = @import("std");

/// The most apps the recents list holds before eviction begins.
pub const max_recents: usize = 16;

/// The result of using an app: where it goes and what, if anything, is evicted.
pub const Update = struct {
    /// The new length of the recents list after the use.
    length_after: usize,
    /// The index in the old list that was evicted, or null if nothing was.
    evicted_index: ?usize,
};

/// Records that an app already in the recents list was used, moving it to the front.
///
/// The app moves to position zero and everything above its old position shifts down by one;
/// the list length is unchanged, and nothing is evicted, because the app was already present.
/// This is the common case: switching back to something recent.
pub fn touchExisting(length: usize) Update {
    return .{ .length_after = length, .evicted_index = null };
}

/// Records that a new app (not in the list) was used, placing it at the front.
///
/// If the list has room, the app is prepended and the length grows by one. If the list is
/// already at its cap, the least-recently-used app — the one at the end — is evicted to make
/// room, so the list stays bounded and the new app takes the front. The evicted index is the
/// old last position.
pub fn addUnseen(length: usize) Update {
    if (length < max_recents) {
        return .{ .length_after = length + 1, .evicted_index = null };
    }
    // Full: evict the least-recently-used (last) entry.
    return .{ .length_after = max_recents, .evicted_index = max_recents - 1 };
}

test "touching an existing app keeps the length and evicts nothing" {
    const update = touchExisting(5);
    try std.testing.expectEqual(@as(usize, 5), update.length_after);
    try std.testing.expectEqual(@as(?usize, null), update.evicted_index);
}

test "adding a new app with room grows the list" {
    const update = addUnseen(5);
    try std.testing.expectEqual(@as(usize, 6), update.length_after);
    try std.testing.expectEqual(@as(?usize, null), update.evicted_index);
}

test "adding a new app when full evicts the least-recently-used" {
    const update = addUnseen(max_recents);
    try std.testing.expectEqual(max_recents, update.length_after);
    try std.testing.expectEqual(@as(?usize, max_recents - 1), update.evicted_index);
}

test "the list never grows past the cap, swept" {
    // The bounded property: after adding a new app at any length, the length never exceeds
    // the cap.
    var length: usize = 0;
    while (length <= max_recents) : (length += 1) {
        const update = addUnseen(length);
        try std.testing.expect(update.length_after <= max_recents);
    }
}

test "eviction only happens when the list is full, swept" {
    // The evict-only-when-full property: an eviction index is returned only at capacity.
    var length: usize = 0;
    while (length <= max_recents) : (length += 1) {
        const update = addUnseen(length);
        if (update.evicted_index != null) try std.testing.expectEqual(max_recents, length);
    }
}
