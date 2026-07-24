//! Deciding whether an app may be launched from the launcher, so a tap opens an installed,
//! permitted app and a restricted or missing one fails clearly rather than half-launching.
//!
//! The launcher turns a tap into a running app, and before it starts anything it checks that
//! the launch should happen at all. The app must be installed — a stale icon for something
//! removed must not launch into nothing, it must say the app is gone. The app must be
//! permitted right now: parental controls may block it, a screen-time limit may have been
//! reached, a work profile may restrict it, and in each case the launcher refuses with the
//! reason rather than opening an app the person is not allowed to use. Only an app that is
//! present and currently permitted launches. Checking this at the launcher, once, means every
//! surface that opens an app — the home screen, search, a shortcut — goes through the same
//! gate, so an app can never be started by finding a back door around the restriction that
//! the main icon respects.
//!
//! This module launches nothing. It decides whether an app may be launched, from its
//! installed state and any active restriction, as a pure function.

const std = @import("std");

/// An app's launch-relevant state.
pub const App = struct {
    /// Whether the app is installed and present.
    installed: bool,
    /// The active restriction on the app, if any.
    restriction: Restriction,
};

/// A restriction that blocks launching an app.
pub const Restriction = enum {
    /// No restriction; the app may launch.
    none,
    /// Blocked by parental controls or a content policy.
    content_blocked,
    /// The app's screen-time allowance is exhausted.
    time_limit_reached,
    /// A work or device policy disallows the app in this context.
    policy_restricted,
};

/// Why a launch was refused.
pub const Refusal = enum {
    /// The app is not installed; the icon is stale.
    not_installed,
    /// The app is present but currently restricted.
    restricted,
};

/// The launch decision.
pub const Decision = union(enum) {
    launch,
    refuse: Refusal,

    pub fn launches(decision: Decision) bool {
        return decision == .launch;
    }
};

/// Decides whether an app may be launched.
///
/// A missing app is refused as not installed, so a stale icon never launches into nothing.
/// A present app under any active restriction is refused as restricted, so a blocked or
/// time-limited app does not open. Only an installed app with no active restriction launches.
pub fn decide(app: App) Decision {
    if (!app.installed) return .{ .refuse = .not_installed };
    if (app.restriction != .none) return .{ .refuse = .restricted };
    return .launch;
}

fn makeApp(installed: bool, restriction: Restriction) App {
    return .{ .installed = installed, .restriction = restriction };
}

test "an installed unrestricted app launches" {
    try std.testing.expect(decide(makeApp(true, .none)).launches());
}

test "a missing app is refused as not installed" {
    try std.testing.expectEqual(Decision{ .refuse = .not_installed }, decide(makeApp(false, .none)));
}

test "a restricted app is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .restricted }, decide(makeApp(true, .content_blocked)));
    try std.testing.expectEqual(Decision{ .refuse = .restricted }, decide(makeApp(true, .time_limit_reached)));
    try std.testing.expectEqual(Decision{ .refuse = .restricted }, decide(makeApp(true, .policy_restricted)));
}

test "the installed check precedes the restriction check" {
    // A missing app reports not-installed even if it also carries a restriction flag.
    try std.testing.expectEqual(Decision{ .refuse = .not_installed }, decide(makeApp(false, .policy_restricted)));
}

test "only an installed, unrestricted app ever launches, swept" {
    // The gate property: whenever a launch happens, the app is installed and unrestricted.
    for ([_]bool{ false, true }) |installed| {
        for (std.enums.values(Restriction)) |restriction| {
            if (decide(makeApp(installed, restriction)).launches()) {
                try std.testing.expect(installed);
                try std.testing.expectEqual(Restriction.none, restriction);
            }
        }
    }
}
