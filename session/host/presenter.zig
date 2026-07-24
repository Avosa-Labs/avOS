//! Deciding which endpoint is presenting a Personal Compute Instance, so exactly one endpoint holds
//! the display at a time and handing it off never duplicates or drops it.
//!
//! A person's instance lives independently of any device, but at any moment it is being *shown*
//! somewhere — a phone, a laptop, a room display — and "shown somewhere" must mean exactly one
//! somewhere. Two endpoints presenting the same instance at once is not a convenience; it is a
//! confused-deputy hazard where an action taken on one surface is mirrored, unseen, on another the
//! person forgot was live. So presentation is a single role the instance grants to one endpoint, and
//! moving it is a handoff: the role leaves the current presenter and arrives at the next in one step,
//! with no window where both hold it and none where the instance is presented nowhere while an
//! endpoint is available. An endpoint may become presenter only if it is trusted and permitted to
//! present; a mere claim is not enough. Keeping presentation a single transferable role is what lets
//! a person walk from one device to another and have their environment follow them intact.
//!
//! This module presents nothing. It decides whether an endpoint may take the presenting role and
//! what the presenter becomes after a handoff, as pure functions.

const std = @import("std");

/// An endpoint's standing for the purpose of presenting.
pub const Endpoint = struct {
    id: u64,
    /// Whether the endpoint's trust is currently valid (not lapsed or revoked).
    trusted: bool,
    /// Whether the endpoint is permitted to present the instance.
    may_present: bool,

    /// Whether this endpoint is eligible to hold the presenting role.
    pub fn eligible(endpoint: Endpoint) bool {
        return endpoint.trusted and endpoint.may_present;
    }
};

/// Who is presenting the instance: exactly one endpoint, or none.
pub const Presenter = union(enum) {
    /// No endpoint currently presents the instance — it still exists, shown nowhere.
    none,
    /// The id of the single endpoint presenting.
    endpoint: u64,
};

/// Whether an endpoint may take the presenting role.
///
/// An endpoint may present only if it is eligible — trusted and permitted. This holds regardless of
/// who presents now, because taking over is still a grant of the role, not something an endpoint may
/// assert for itself.
pub fn mayPresent(endpoint: Endpoint) bool {
    return endpoint.eligible();
}

/// The presenter after handing the role to a new endpoint.
///
/// If the endpoint is eligible, it becomes the sole presenter — whoever presented before no longer
/// does, so the role is never held by two at once. If it is not eligible the handoff is refused and
/// the presenter is unchanged, so an ineligible endpoint can neither seize the role nor knock the
/// current presenter off it.
pub fn handoff(current: Presenter, next: Endpoint) Presenter {
    if (!next.eligible()) return current;
    return .{ .endpoint = next.id };
}

fn makeEndpoint(id: u64, trusted: bool, may_present: bool) Endpoint {
    return .{ .id = id, .trusted = trusted, .may_present = may_present };
}

test "an eligible endpoint may present" {
    try std.testing.expect(mayPresent(makeEndpoint(1, true, true)));
}

test "an untrusted or non-presenting endpoint may not present" {
    try std.testing.expect(!mayPresent(makeEndpoint(1, false, true)));
    try std.testing.expect(!mayPresent(makeEndpoint(1, true, false)));
}

test "handing off to an eligible endpoint makes it the sole presenter" {
    const after = handoff(.{ .endpoint = 1 }, makeEndpoint(2, true, true));
    try std.testing.expectEqual(Presenter{ .endpoint = 2 }, after);
}

test "handing off to an ineligible endpoint leaves the presenter unchanged" {
    const before = Presenter{ .endpoint = 1 };
    try std.testing.expectEqual(before, handoff(before, makeEndpoint(2, false, true)));
}

test "a handoff never results in two presenters, swept" {
    // The single-presenter property: after any handoff the presenter is exactly one endpoint or
    // none — the union type admits no third state, and an eligible next always replaces, never adds.
    const currents = [_]Presenter{ .none, .{ .endpoint = 1 } };
    for (currents) |current| {
        for ([_]bool{ false, true }) |trusted| {
            for ([_]bool{ false, true }) |present| {
                const after = handoff(current, makeEndpoint(9, trusted, present));
                if (trusted and present) {
                    try std.testing.expectEqual(Presenter{ .endpoint = 9 }, after);
                } else {
                    try std.testing.expectEqual(current, after);
                }
            }
        }
    }
}
