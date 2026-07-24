//! Choosing which network to register on, so the device prefers the home carrier, roams only
//! when allowed, and always keeps emergency calling even when it can register on nothing.
//!
//! A phone that can see several networks must choose one, and the choice balances cost,
//! coverage, and a safety floor. The home carrier is preferred whenever it is reachable,
//! because it is what the person pays for and roams at no extra cost. When the home network is
//! not available, a partner network may be used — but roaming can cost money, so the device
//! registers on one only if the person has allowed roaming; if they have not, it does not
//! silently rack up charges. And underneath all of it is a floor that never lowers: even when
//! the device can register on no network it is entitled to use — home unreachable, roaming off
//! or no partner — it still camps on whatever network it can reach for emergency calls alone,
//! because a phone that cannot call for help because it had no plan is a phone that failed at
//! the one thing it must always do. So selection prefers home, falls back to permitted
//! roaming, and otherwise holds an emergency-only registration.
//!
//! This module registers on no network. It chooses a registration outcome from what is
//! available and whether roaming is allowed, as a pure function.

const std = @import("std");

/// What networks the device can currently see.
pub const Available = struct {
    /// Whether the home carrier's network is reachable.
    home_reachable: bool,
    /// Whether any roaming partner network is reachable.
    partner_reachable: bool,
    /// Whether at least one network — any network — is reachable for emergency calls.
    any_network_reachable: bool,
};

/// The registration the device settles on.
pub const Registration = enum {
    /// Registered on the home carrier: full service, no roaming cost.
    home,
    /// Registered on a roaming partner: full service, may cost money.
    roaming,
    /// Registered for emergency calls only: no plan applies, but help is still reachable.
    emergency_only,
    /// No network at all is reachable, not even for emergency.
    no_service,
};

/// Chooses the registration, given what is available and whether roaming is allowed.
///
/// The home carrier is chosen whenever reachable. Otherwise, if a partner is reachable and the
/// person has allowed roaming, the device roams; without permission it does not, to avoid
/// silent charges. When neither full-service option applies, the device falls to
/// emergency-only if any network at all is reachable, so help is always dialable; only when no
/// network is reachable at all is there no service.
pub fn select(available: Available, roaming_allowed: bool) Registration {
    if (available.home_reachable) return .home;
    if (available.partner_reachable and roaming_allowed) return .roaming;
    if (available.any_network_reachable) return .emergency_only;
    return .no_service;
}

fn avail(home: bool, partner: bool, any: bool) Available {
    return .{ .home_reachable = home, .partner_reachable = partner, .any_network_reachable = any };
}

test "the home carrier is preferred when reachable" {
    try std.testing.expectEqual(Registration.home, select(avail(true, true, true), true));
    // Home wins even if roaming is disallowed.
    try std.testing.expectEqual(Registration.home, select(avail(true, false, true), false));
}

test "a partner is used when home is down and roaming is allowed" {
    try std.testing.expectEqual(Registration.roaming, select(avail(false, true, true), true));
}

test "roaming is not used without permission" {
    // Partner reachable but roaming off: fall to emergency-only, not roaming.
    try std.testing.expectEqual(Registration.emergency_only, select(avail(false, true, true), false));
}

test "emergency-only holds when no full-service option applies but a network is reachable" {
    try std.testing.expectEqual(Registration.emergency_only, select(avail(false, false, true), true));
}

test "no service only when no network at all is reachable" {
    try std.testing.expectEqual(Registration.no_service, select(avail(false, false, false), true));
}

test "emergency remains available whenever any network is reachable, swept" {
    // The safety-floor property: whenever any network is reachable, the device never lands on
    // no_service — it is at least emergency-capable.
    for ([_]bool{ false, true }) |home| {
        for ([_]bool{ false, true }) |partner| {
            for ([_]bool{ false, true }) |roaming| {
                const registration = select(avail(home, partner, true), roaming);
                try std.testing.expect(registration != .no_service);
            }
        }
    }
}

test "roaming never happens without permission, swept" {
    // The no-silent-charges property: a roaming registration only ever occurs with roaming
    // allowed.
    for ([_]bool{ false, true }) |home| {
        for ([_]bool{ false, true }) |partner| {
            const registration = select(avail(home, partner, true), false);
            try std.testing.expect(registration != .roaming);
        }
    }
}
