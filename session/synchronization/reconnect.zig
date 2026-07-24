//! Deciding what state is sent to a reconnecting endpoint, so it catches up on what it missed without
//! ever receiving state its trust level forbids.
//!
//! An endpoint drops off and comes back — a laptop that slept, a phone that lost signal — holding
//! state as of the version it last acknowledged. Bringing it current means sending the changes since
//! then, and two constraints shape what actually goes on the wire. First, send only the delta: the
//! updates after the endpoint's acknowledged version, not the whole state, because resending
//! everything is both wasteful and a way for stale data to slip back in. Second, and overriding, send
//! only the state categories the endpoint is trusted to hold: a presenting-only surface gets
//! presentation state and never the secret or durable-personal categories, no matter that they
//! changed while it was away. Reconnection is exactly the moment this is easy to get wrong — a bulk
//! catch-up that ships the whole delta including secrets to a room display. Filtering the delta by the
//! endpoint's category trust is what lets an endpoint resync seamlessly without the resync becoming a
//! leak.
//!
//! This module sends nothing. It decides whether a given state change is included in a reconnecting
//! endpoint's catch-up, from the change's version, category, and the endpoint's trust, as pure
//! functions.

const std = @import("std");

/// A category of instance state, distinguished by where it may travel.
pub const Category = enum {
    /// Renderable state safe to show anywhere that may present.
    presentation,
    /// Durable personal data — synchronized only to endpoints trusted to hold it.
    durable_personal,
    /// Secret material that leaves the instance for no endpoint.
    secret,
};

/// How much state an endpoint is trusted to hold.
pub const Trust = enum {
    /// May hold only presentation state.
    presenting_only,
    /// May hold presentation and durable-personal state (but never secrets).
    trusted_personal,
};

/// A committed change awaiting delivery to an endpoint.
pub const Change = struct {
    /// The instance version at which this change was committed.
    version: u64,
    category: Category,
};

/// Whether an endpoint's trust permits it to receive a category of state.
fn permitsCategory(trust: Trust, category: Category) bool {
    return switch (category) {
        .presentation => true,
        .durable_personal => trust == .trusted_personal,
        .secret => false, // Secret state reaches no endpoint.
    };
}

/// Whether a change is included in a reconnecting endpoint's catch-up.
///
/// The change is included only if it is newer than the version the endpoint acknowledged — part of
/// the delta — and its category is one the endpoint's trust permits. Both must hold: an old change is
/// not resent, and a change the endpoint is not trusted to hold is withheld even though it is part of
/// the delta, so catching up never delivers a forbidden category.
pub fn include(change: Change, acknowledged_version: u64, trust: Trust) bool {
    return change.version > acknowledged_version and permitsCategory(trust, change.category);
}

test "a newer presentation change is sent to any endpoint" {
    try std.testing.expect(include(.{ .version = 5, .category = .presentation }, 3, .presenting_only));
}

test "an already-acknowledged change is not resent" {
    try std.testing.expect(!include(.{ .version = 3, .category = .presentation }, 3, .trusted_personal));
}

test "durable-personal state is withheld from a presenting-only endpoint" {
    try std.testing.expect(!include(.{ .version = 5, .category = .durable_personal }, 3, .presenting_only));
    try std.testing.expect(include(.{ .version = 5, .category = .durable_personal }, 3, .trusted_personal));
}

test "secret state reaches no endpoint on reconnect" {
    try std.testing.expect(!include(.{ .version = 9, .category = .secret }, 0, .trusted_personal));
}

test "no included change ever violates the endpoint's category trust, swept" {
    // The catch-up-safety property: an included change is always both in the delta and category-
    // permitted for the endpoint.
    const categories = [_]Category{ .presentation, .durable_personal, .secret };
    for (categories) |category| {
        for ([_]Trust{ .presenting_only, .trusted_personal }) |trust| {
            var version: u64 = 1;
            while (version <= 5) : (version += 1) {
                const change = Change{ .version = version, .category = category };
                if (include(change, 3, trust)) {
                    try std.testing.expect(version > 3);
                    try std.testing.expect(permitsCategory(trust, category));
                }
            }
        }
    }
}
