//! The cellular modem, and the one call it must never refuse.
//!
//! A modem is a radio that reaches outward, gated like any device that
//! transmits. But it carries a duty no other radio does: it must place an
//! emergency call even when nothing else about the device would allow it — no
//! subscriber identity, no service, a locked screen, an empty account. A phone
//! that could not call for help because the account lapsed would be a phone that
//! failed at the one moment a phone must not. This module holds the policy for
//! what the modem may do in each registration state, and the rule that emergency
//! calling is exempt from all of it.
//!
//! It commands no radio. It answers whether a given operation is permitted in
//! the modem's current state, as a pure function, so the emergency exemption is
//! verified rather than trusted.

const std = @import("std");

/// How the modem is registered on a network.
///
/// Ordered by how much the device may do: more service permits more operations,
/// but the least service still permits an emergency call.
pub const Registration = enum {
    /// No signal at all. Only what needs no network is possible.
    no_service,
    /// A network is reachable but the device is not registered for service on
    /// it — no valid subscriber identity, or roaming barred. Emergency calling
    /// is still possible, because networks carry emergency calls for any device.
    emergency_only,
    /// Registered for normal service, but roaming on another carrier.
    roaming,
    /// Registered for normal service on the home network.
    home,

    /// Whether normal (non-emergency) calls and data are possible.
    pub fn permitsNormalService(registration: Registration) bool {
        return switch (registration) {
            .no_service, .emergency_only => false,
            .roaming, .home => true,
        };
    }
};

/// What the device wants the modem to do.
pub const Operation = enum {
    /// Place an emergency call. The operation that must almost always be
    /// permitted.
    emergency_call,
    /// Place a normal voice call.
    voice_call,
    /// Send or receive a text message.
    messaging,
    /// Move data over the cellular network.
    data,

    pub fn isEmergency(operation: Operation) bool {
        return operation == .emergency_call;
    }
};

/// What the device knows about itself when it asks.
pub const Situation = struct {
    /// Whether a valid subscriber identity is present. Normal service needs one;
    /// an emergency call does not.
    has_subscriber_identity: bool,
    /// Whether the account is in good standing. Same asymmetry.
    account_in_good_standing: bool,
    /// Whether the screen is locked. A locked phone still places emergency
    /// calls; that is why an emergency dialler is reachable from the lock
    /// screen.
    screen_locked: bool,
};

/// Whether an operation is permitted.
///
/// The emergency exemption is the first thing checked and it is unconditional:
/// if a network of any kind is reachable — anything but `no_service` — an
/// emergency call is permitted regardless of subscriber identity, account
/// standing, or lock state. Everything else requires normal service, a
/// subscriber identity, and an account in good standing, and any operation but
/// an emergency call is refused on a locked screen.
pub fn permits(
    registration: Registration,
    operation: Operation,
    situation: Situation,
) bool {
    if (operation.isEmergency()) {
        // The one rule the whole module exists for: an emergency call goes
        // through on any reachable network, whatever the device's own state.
        return registration != .no_service;
    }

    // Everything else is a normal operation, gated fully.
    if (!registration.permitsNormalService()) return false;
    if (!situation.has_subscriber_identity) return false;
    if (!situation.account_in_good_standing) return false;
    if (situation.screen_locked) return false;
    return true;
}

const no_identity: Situation = .{
    .has_subscriber_identity = false,
    .account_in_good_standing = false,
    .screen_locked = true,
};

const full_service: Situation = .{
    .has_subscriber_identity = true,
    .account_in_good_standing = true,
    .screen_locked = false,
};

test "an emergency call goes through with no identity, no account, screen locked" {
    // The single most important property: a phone calls for help even when
    // nothing else about it would allow anything.
    try std.testing.expect(permits(.emergency_only, .emergency_call, no_identity));
    try std.testing.expect(permits(.home, .emergency_call, no_identity));
    try std.testing.expect(permits(.roaming, .emergency_call, no_identity));
}

test "an emergency call still needs a reachable network" {
    // With no signal at all there is no network to carry it, and no policy can
    // conjure one.
    try std.testing.expect(!permits(.no_service, .emergency_call, full_service));
}

test "a normal call needs full service and a good account" {
    try std.testing.expect(permits(.home, .voice_call, full_service));
    try std.testing.expect(!permits(.emergency_only, .voice_call, full_service));
    try std.testing.expect(!permits(.no_service, .voice_call, full_service));
}

test "a normal call is refused without a subscriber identity" {
    var situation = full_service;
    situation.has_subscriber_identity = false;
    try std.testing.expect(!permits(.home, .voice_call, situation));
}

test "a normal call is refused on a lapsed account" {
    var situation = full_service;
    situation.account_in_good_standing = false;
    try std.testing.expect(!permits(.home, .voice_call, situation));
}

test "normal operations are refused on a locked screen but emergency is not" {
    var situation = full_service;
    situation.screen_locked = true;
    try std.testing.expect(!permits(.home, .voice_call, situation));
    try std.testing.expect(!permits(.home, .messaging, situation));
    try std.testing.expect(!permits(.home, .data, situation));
    // The exception.
    try std.testing.expect(permits(.home, .emergency_call, situation));
}

test "roaming permits normal service" {
    try std.testing.expect(permits(.roaming, .data, full_service));
}

test "emergency-only registration lives up to its name" {
    // It permits an emergency call and nothing else.
    try std.testing.expect(permits(.emergency_only, .emergency_call, no_identity));
    for ([_]Operation{ .voice_call, .messaging, .data }) |operation| {
        try std.testing.expect(!permits(.emergency_only, operation, full_service));
    }
}

test "no non-emergency operation is ever permitted without normal service" {
    // Swept: for every registration lacking normal service and every non-
    // emergency operation, permission is refused whatever the situation.
    for ([_]Registration{ .no_service, .emergency_only }) |registration| {
        for ([_]Operation{ .voice_call, .messaging, .data }) |operation| {
            try std.testing.expect(!permits(registration, operation, full_service));
        }
    }
}

test "an emergency call is permitted from every serviced state" {
    // Swept the other way: on any reachable network, whatever the situation, an
    // emergency call is permitted.
    for ([_]Registration{ .emergency_only, .roaming, .home }) |registration| {
        for ([_]Situation{ no_identity, full_service }) |situation| {
            try std.testing.expect(permits(registration, .emergency_call, situation));
        }
    }
}
