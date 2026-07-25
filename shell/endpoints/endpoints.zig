//! Deciding whether an active session may move to another endpoint, so a handoff carries the
//! person's authority only to a place that has already earned it.
//!
//! Handing a session from phone to tablet to desktop is meant to feel seamless, but a handoff
//! is not just moving a window: it moves the session's authority to act as the person. So the
//! target endpoint must clear the same bar the session itself did. It must belong to the same
//! account, so the session is not crossing to a stranger; it must be a trusted endpoint the
//! person has paired, not an arbitrary nearby device; and it must be authenticated right now,
//! so the authority lands with the person and not with whoever is holding an unlocked device.
//! Miss any one and the handoff is refused, because the convenience is never worth leaking the
//! session's authority.
//!
//! This module moves nothing. It decides whether a session may hand off to a target endpoint,
//! as a pure function over that endpoint's account, trust, and authentication state.

const std = @import("std");

/// A device that could receive a handed-off session, kept for display and policy elsewhere.
pub const Endpoint = enum { phone, tablet, desktop, wearable, car };

/// The security posture of a candidate handoff target at the moment of the decision.
pub const Target = struct {
    /// Whether someone is authenticated on the endpoint right now.
    authenticated: bool,
    /// Whether the person has previously paired and trusted this endpoint.
    trusted: bool,
    /// Whether the endpoint is signed in to the same account as the session.
    same_account: bool,
};

/// Whether an active session may hand off to the target endpoint.
///
/// A session moves only to an endpoint that is same-account, trusted, and authenticated, all
/// three together, because the handoff transfers the session's authority and any weaker target
/// would receive authority it has not earned. The default is refusal.
pub fn mayHandoff(target: Target) bool {
    return target.same_account and target.trusted and target.authenticated;
}

test "a same-account trusted authenticated endpoint may receive the handoff" {
    try std.testing.expect(mayHandoff(.{ .authenticated = true, .trusted = true, .same_account = true }));
}

test "an unauthenticated endpoint is refused" {
    try std.testing.expect(!mayHandoff(.{ .authenticated = false, .trusted = true, .same_account = true }));
}

test "a foreign-account endpoint is refused even when trusted and authenticated" {
    try std.testing.expect(!mayHandoff(.{ .authenticated = true, .trusted = true, .same_account = false }));
}

test "an untrusted endpoint is refused" {
    try std.testing.expect(!mayHandoff(.{ .authenticated = true, .trusted = false, .same_account = true }));
}

test "a handoff is refused unless the target is same-account and trusted and authenticated, swept" {
    // The authority-integrity property: over every combination of the three flags, a handoff is
    // permitted only when all three hold.
    for ([_]bool{ false, true }) |authenticated| {
        for ([_]bool{ false, true }) |trusted| {
            for ([_]bool{ false, true }) |same_account| {
                const target: Target = .{ .authenticated = authenticated, .trusted = trusted, .same_account = same_account };
                const all = authenticated and trusted and same_account;
                try std.testing.expectEqual(all, mayHandoff(target));
            }
        }
    }
}
