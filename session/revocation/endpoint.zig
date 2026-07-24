//! Deciding whether a revoked endpoint's next operation is refused, so withdrawing an endpoint takes
//! effect immediately rather than at some future reconnection.
//!
//! The reason an owner revokes an endpoint is usually that it has left their control — a lost phone, a
//! shared screen they walked away from, a borrowed laptop returned. That threat is present *now*, so
//! revocation has to bite *now*: on the endpoint's very next operation, not the next time it happens
//! to reconnect. An endpoint holding an open session when it is revoked is revoked in place, and its
//! next attempt to present, act, or approve is refused, because waiting for a reconnection that may
//! never come would leave the withdrawn endpoint able to keep operating for as long as it stays
//! connected — precisely the window an attacker wants. Revocation is also monotonic: once withdrawn,
//! an endpoint does not quietly become valid again by reconnecting; it must be re-granted. Enforcing
//! withdrawal at the next operation is what makes "revoke this device" a real, immediate loss of
//! access rather than a request the device may outrun.
//!
//! This module withdraws nothing. It decides whether an endpoint's operation is permitted given its
//! revocation state, as a pure function.

const std = @import("std");

/// An endpoint's standing at the moment it attempts an operation.
pub const Standing = enum {
    /// The endpoint's grant is valid.
    active,
    /// The endpoint has been revoked; withdrawal is in effect.
    revoked,
};

/// Whether an endpoint's operation is permitted.
///
/// An active endpoint's operation is permitted; a revoked endpoint's is refused. The check is applied
/// to every operation, so a revoked endpoint that is still connected is stopped at its next action
/// rather than being allowed to continue until it reconnects.
pub fn mayOperate(standing: Standing) bool {
    return standing == .active;
}

/// The standing after a revocation is applied to a current standing.
///
/// Revocation is monotonic: revoking moves an endpoint to revoked, and a reconnection does not
/// restore it — only a fresh grant does, which is outside this decision. Applying revocation to an
/// already-revoked endpoint leaves it revoked.
pub fn revoke(_: Standing) Standing {
    return .revoked;
}

test "an active endpoint may operate" {
    try std.testing.expect(mayOperate(.active));
}

test "a revoked endpoint's next operation is refused" {
    try std.testing.expect(!mayOperate(.revoked));
}

test "revocation moves any standing to revoked" {
    try std.testing.expectEqual(Standing.revoked, revoke(.active));
    try std.testing.expectEqual(Standing.revoked, revoke(.revoked));
}

test "no revoked endpoint ever operates, swept" {
    // The immediate-withdrawal property: after revocation the endpoint may not operate, whatever it
    // was before.
    for ([_]Standing{ .active, .revoked }) |before| {
        try std.testing.expect(!mayOperate(revoke(before)));
    }
}
