//! Advancing a message's delivery state forward only, so a message's status never lies by
//! regressing from delivered back to sending.
//!
//! A message carries a status a person reads to know where it stands: sending, sent,
//! delivered, read. That status is a promise, and the promise is broken the moment it moves
//! backward. If a message shown as delivered flips back to sending because a duplicate network
//! acknowledgement arrived late, the person believes their message was lost when it was not,
//! and re-sends it, and now it is sent twice. So delivery status only ever advances: sending
//! to sent to delivered to read, and never the other way. A status update that would regress
//! is ignored, because it is stale information about a message that has already moved on. And
//! a message is identified by a stable id, so a duplicate delivery of the same message is
//! recognized as the one message it is rather than shown twice. Forward-only status and
//! id-based de-duplication are what make a conversation's delivery marks trustworthy.
//!
//! This module sends no message. It decides whether a status update may advance a message and
//! whether an incoming message is a duplicate, as pure functions.

const std = @import("std");

/// A message's delivery status, ordered from earliest to latest.
pub const Status = enum(u8) {
    /// Being sent; not yet acknowledged by the network.
    sending = 0,
    /// Accepted by the network.
    sent = 1,
    /// Delivered to the recipient's device.
    delivered = 2,
    /// Read by the recipient.
    read = 3,

    fn order(status: Status) u8 {
        return @intFromEnum(status);
    }
};

/// Whether a status may advance from `current` to `proposed`.
///
/// The proposed status must be at least as advanced as the current one; a later or equal
/// status advances (equal is a harmless no-op), and an earlier one is rejected as stale, so a
/// message's status never regresses. This is what keeps a delivered message from flipping back
/// to sending on a late duplicate acknowledgement.
pub fn mayAdvance(current: Status, proposed: Status) bool {
    return proposed.order() >= current.order();
}

/// Whether an incoming message with `id` is a duplicate of one already seen. A message is
/// identified by a stable id, so the same message arriving twice is recognized rather than
/// shown twice.
pub fn isDuplicate(id: u64, seen_ids: []const u64) bool {
    for (seen_ids) |seen| {
        if (seen == id) return true;
    }
    return false;
}

test "status advances forward" {
    try std.testing.expect(mayAdvance(.sending, .sent));
    try std.testing.expect(mayAdvance(.sent, .delivered));
    try std.testing.expect(mayAdvance(.delivered, .read));
}

test "status does not regress" {
    try std.testing.expect(!mayAdvance(.delivered, .sending));
    try std.testing.expect(!mayAdvance(.read, .delivered));
}

test "an equal status is a harmless no-op" {
    try std.testing.expect(mayAdvance(.delivered, .delivered));
}

test "status may skip forward" {
    // A message can jump from sending straight to read if that is what the network reports.
    try std.testing.expect(mayAdvance(.sending, .read));
}

test "a repeated message id is a duplicate" {
    const seen = [_]u64{ 1, 2, 3 };
    try std.testing.expect(isDuplicate(2, &seen));
    try std.testing.expect(!isDuplicate(9, &seen));
}

test "no status ever regresses, swept" {
    // The forward-only property: an advance is allowed exactly when the proposed status is at
    // least the current one.
    const statuses = [_]Status{ .sending, .sent, .delivered, .read };
    for (statuses) |current| {
        for (statuses) |proposed| {
            try std.testing.expectEqual(proposed.order() >= current.order(), mayAdvance(current, proposed));
        }
    }
}
