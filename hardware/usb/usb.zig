//! Deciding what a cable is allowed to do when it is plugged in.
//!
//! A charging cable and a data cable look identical, and a malicious charger — a
//! public port, a borrowed brick, a gift — can try to be both. The attack is old
//! and simple: the device is plugged in to charge, and the port quietly asks to
//! mount its storage or drive it as a host. So a connection does not grant data
//! access by being physical. It charges by default, and data is unlocked only by
//! a present, deliberate person, and this module decides which a given
//! connection gets.
//!
//! It drives no bus. It answers what a connection is permitted to do given the
//! device's state and what the person has allowed, as a pure function, so the
//! rule that a locked phone only ever charges is verified rather than trusted.

const std = @import("std");

/// What a connection is trying to do.
///
/// Ordered by exposure: taking power reveals nothing, moving files exposes the
/// person's data, and acting as a host lets the device drive the peripheral,
/// which is the most it can do.
pub const Role = enum {
    /// Draw power only. Always safe; nothing of the person's is exposed.
    charge_only,
    /// Transfer files to or from the device's storage.
    data_transfer,
    /// Act as a USB host driving an attached peripheral: a keyboard, a drive, a
    /// display.
    host_peripheral,
    /// Debug access: full control of the device for development. The most
    /// dangerous role, and the one that must be explicitly, separately enabled.
    debug,

    /// Whether this role exposes the person's data or hands over control.
    pub fn exposesData(role: Role) bool {
        return role != .charge_only;
    }
};

/// What the device knows about the connection and its own state.
pub const Situation = struct {
    /// Whether the screen is unlocked. A locked phone only charges, whatever the
    /// cable asks for.
    unlocked: bool,
    /// Whether the person has, for this connection, allowed data access. A
    /// per-connection consent, not a global setting, so unplugging revokes it.
    data_allowed_this_connection: bool,
    /// Whether developer debugging is enabled at all. Off by default; a person
    /// turns it on deliberately and it stays a separate decision from ordinary
    /// data access.
    debugging_enabled: bool,
};

/// Why a role was refused.
pub const Refusal = enum {
    /// The device is locked. Only charging is possible.
    device_locked,
    /// The person has not allowed data on this connection.
    data_not_allowed,
    /// Debugging is not enabled.
    debugging_disabled,
};

/// What the connection may do.
pub const Decision = union(enum) {
    allow,
    /// The requested role is refused; the connection still charges.
    charge_only: Refusal,

    pub fn allowsRequestedRole(decision: Decision) bool {
        return decision == .allow;
    }
};

/// Decides what a connection may do.
///
/// Charging is always allowed and needs no permission, so a refusal never means
/// a dead battery — it means the cable charges but does nothing else. Data
/// requires an unlocked device and a consent given for this connection; debug
/// requires that plus debugging having been deliberately enabled. A locked
/// device grants nothing beyond charge, which is the property the whole module
/// exists to hold.
pub fn decide(role: Role, situation: Situation) Decision {
    // Power is always fine and asks nothing of the person.
    if (role == .charge_only) return .allow;

    // Anything that exposes data needs an unlocked device. A locked phone in a
    // hostile port only ever charges.
    if (!situation.unlocked) return .{ .charge_only = .device_locked };

    // And a consent given for this specific connection, so unplugging and
    // replugging asks again.
    if (!situation.data_allowed_this_connection) return .{ .charge_only = .data_not_allowed };

    // Debug is a separate, deliberate enablement on top of everything else.
    if (role == .debug and !situation.debugging_enabled) {
        return .{ .charge_only = .debugging_disabled };
    }

    return .allow;
}

const consented: Situation = .{
    .unlocked = true,
    .data_allowed_this_connection = true,
    .debugging_enabled = false,
};

test "charging is always allowed" {
    // Whatever the device state, power is fine. A refusal must never cost a
    // person their charge.
    for ([_]bool{ true, false }) |unlocked| {
        const situation: Situation = .{
            .unlocked = unlocked,
            .data_allowed_this_connection = false,
            .debugging_enabled = false,
        };
        try std.testing.expect(decide(.charge_only, situation).allowsRequestedRole());
    }
}

test "a locked device only charges" {
    var locked = consented;
    locked.unlocked = false;
    // The core attack: plugged in to charge, the port asks for data. Locked, it
    // gets none.
    try std.testing.expectEqual(
        Decision{ .charge_only = .device_locked },
        decide(.data_transfer, locked),
    );
    try std.testing.expectEqual(
        Decision{ .charge_only = .device_locked },
        decide(.host_peripheral, locked),
    );
}

test "data needs a consent given for this connection" {
    var no_consent = consented;
    no_consent.data_allowed_this_connection = false;
    try std.testing.expectEqual(
        Decision{ .charge_only = .data_not_allowed },
        decide(.data_transfer, no_consent),
    );
    // With consent, it is allowed.
    try std.testing.expect(decide(.data_transfer, consented).allowsRequestedRole());
}

test "debug needs debugging enabled on top of data consent" {
    // Consented for data, but debugging not enabled: debug is still refused.
    try std.testing.expectEqual(
        Decision{ .charge_only = .debugging_disabled },
        decide(.debug, consented),
    );

    var debug_ready = consented;
    debug_ready.debugging_enabled = true;
    try std.testing.expect(decide(.debug, debug_ready).allowsRequestedRole());
}

test "no data role is ever allowed on a locked device" {
    // Swept: for every data-exposing role and every consent and debug setting,
    // a locked device refuses.
    var locked: Situation = .{
        .unlocked = false,
        .data_allowed_this_connection = true,
        .debugging_enabled = true,
    };
    _ = &locked;
    for ([_]Role{ .data_transfer, .host_peripheral, .debug }) |role| {
        try std.testing.expect(!decide(role, locked).allowsRequestedRole());
    }
}

test "only charge-only exposes nothing" {
    try std.testing.expect(!Role.charge_only.exposesData());
    try std.testing.expect(Role.data_transfer.exposesData());
    try std.testing.expect(Role.host_peripheral.exposesData());
    try std.testing.expect(Role.debug.exposesData());
}

test "a refused data role still leaves the device charging" {
    // The distinction the return type carries: refusing data is not refusing
    // power.
    var locked = consented;
    locked.unlocked = false;
    const decision = decide(.data_transfer, locked);
    try std.testing.expect(!decision.allowsRequestedRole());
    try std.testing.expect(decision == .charge_only);
}
