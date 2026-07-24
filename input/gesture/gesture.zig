//! Recognizing a swipe from a movement, so a deliberate flick is turned into a direction
//! and an incidental wiggle is ignored.
//!
//! A swipe is one of the most-used gestures, and recognizing it well is a matter of not
//! being too eager. Every touch that moves produces a delta, and if any movement counted
//! as a swipe, a person scrolling or just resting a moving finger would trigger swipes
//! constantly. So a swipe is recognized only when the movement is decisive: it must cover
//! more than a minimum distance, so a small wiggle is not a swipe, and it must be clearly
//! along one axis rather than diagonal, so an ambiguous movement is not forced into a
//! direction it did not really have. When both hold, the swipe's direction is the axis it
//! travelled furthest along. A movement that is too short, or too diagonal to call, is
//! reported as no swipe rather than guessed, because a wrong direction is worse than none
//! — it sends the interface somewhere the person did not intend.
//!
//! This module tracks no touch. It recognizes a swipe and its direction from a movement
//! delta, as a pure function over the horizontal and vertical distances.

const std = @import("std");

/// The minimum distance, in device units, a movement must cover to be a swipe. Below this
/// it is an incidental wiggle.
pub const min_swipe_distance: u32 = 40;

/// How much longer the dominant axis must be than the other for the direction to be
/// unambiguous, as a numerator over a denominator (3/2 means 1.5x). A movement too close
/// to diagonal is not called.
pub const dominance_numerator: u32 = 3;
pub const dominance_denominator: u32 = 2;

/// The direction of a recognized swipe.
pub const Direction = enum { left, right, up, down };

/// The outcome of recognizing a movement.
pub const Recognition = union(enum) {
    /// A swipe in this direction.
    swipe: Direction,
    /// No swipe: too short or too diagonal to call.
    none,

    pub fn recognized(recognition: Recognition) bool {
        return recognition == .swipe;
    }
};

/// Recognizes a swipe from a movement delta.
///
/// `dx` and `dy` are the signed horizontal and vertical distances. A movement whose total
/// travel along its dominant axis is below the minimum distance is not a swipe. A movement
/// whose two axes are too close in magnitude — neither dominant by the required ratio — is
/// too diagonal to call and is not a swipe. Otherwise the direction is the sign of the
/// dominant axis, so the swipe goes the way it actually travelled.
pub fn recognize(dx: i32, dy: i32) Recognition {
    const ax = @abs(dx);
    const ay = @abs(dy);
    const horizontal_dominant = ax >= ay;
    const major = if (horizontal_dominant) ax else ay;
    const minor = if (horizontal_dominant) ay else ax;

    if (major < min_swipe_distance) return .none;
    // Dominance: major must exceed minor by the required ratio.
    if (@as(u64, major) * dominance_denominator < @as(u64, minor) * dominance_numerator) {
        return .none; // too diagonal
    }
    if (horizontal_dominant) {
        return .{ .swipe = if (dx > 0) .right else .left };
    }
    return .{ .swipe = if (dy > 0) .down else .up };
}

test "a decisive horizontal movement is a swipe" {
    try std.testing.expectEqual(Recognition{ .swipe = .right }, recognize(100, 5));
    try std.testing.expectEqual(Recognition{ .swipe = .left }, recognize(-100, 5));
}

test "a decisive vertical movement is a swipe" {
    try std.testing.expectEqual(Recognition{ .swipe = .down }, recognize(5, 100));
    try std.testing.expectEqual(Recognition{ .swipe = .up }, recognize(5, -100));
}

test "a movement below the minimum distance is not a swipe" {
    try std.testing.expectEqual(Recognition.none, recognize(20, 0));
}

test "a near-diagonal movement is too ambiguous to call" {
    // 60 across and 55 down: neither axis dominant by 1.5x.
    try std.testing.expectEqual(Recognition.none, recognize(60, 55));
}

test "a clearly dominant axis past the distance is recognized" {
    // 100 across, 40 down: 100 >= 40 * 1.5, so horizontal wins.
    try std.testing.expectEqual(Recognition{ .swipe = .right }, recognize(100, 40));
}

test "no swipe is recognized below the minimum distance, swept" {
    // The not-too-eager property: whatever the direction, a short movement is never a
    // swipe.
    var d: i32 = -(@as(i32, min_swipe_distance) - 1);
    while (d < @as(i32, min_swipe_distance)) : (d += 5) {
        try std.testing.expect(!recognize(d, 0).recognized());
        try std.testing.expect(!recognize(0, d).recognized());
    }
}

test "a recognized swipe's direction matches its dominant axis, swept" {
    // The correct-direction property: a recognized horizontal swipe goes left/right and a
    // vertical one up/down, matching the sign.
    const deltas = [_][2]i32{ .{ 100, 10 }, .{ -100, 10 }, .{ 10, 100 }, .{ 10, -100 } };
    for (deltas) |d| {
        switch (recognize(d[0], d[1])) {
            .swipe => |dir| {
                if (@abs(d[0]) >= @abs(d[1])) {
                    try std.testing.expect(dir == .left or dir == .right);
                } else {
                    try std.testing.expect(dir == .up or dir == .down);
                }
            },
            .none => {},
        }
    }
}
