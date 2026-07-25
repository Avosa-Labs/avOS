//! Deciding, per capability, whether it works fully, degraded, or not at all with no network,
//! so the device stays honestly useful offline instead of failing in surprising places.
//!
//! When the network drops, a person should still know exactly what they can do. A capability
//! that runs on the device — the on-device agent, local files, the camera — keeps working in
//! full, because nothing it needs left the device. A capability that is fundamentally a call to
//! somewhere else — cloud sync, a remote model — cannot pretend to work, so it reports itself
//! unavailable rather than hanging. Messaging sits between: it degrades, accepting what the
//! person writes and queuing it to send the moment a connection returns, so the offline state
//! is a delay rather than a wall.
//!
//! This module sends nothing. It decides a capability's availability, as a pure function over
//! the capability and whether the device is online.

const std = @import("std");

/// A device capability whose offline behavior differs by where its work actually happens.
pub const Capability = enum {
    on_device_agent,
    local_files,
    camera,
    cloud_sync,
    remote_model,
    messaging,
};

/// How much of a capability is usable right now.
pub const Availability = enum {
    /// Works completely.
    full,
    /// Works in a reduced form, e.g. queuing an action to complete later.
    degraded,
    /// Cannot be used at all until the condition clears.
    unavailable,
};

/// Whether a capability inherently needs the network to function at all.
///
/// Named as its own predicate so the offline invariant — that a network-bound capability is
/// never reported `full` while offline — can be checked directly against the same truth the
/// decision uses.
pub fn needsNetwork(capability: Capability) bool {
    return switch (capability) {
        .on_device_agent, .local_files, .camera => false,
        .cloud_sync, .remote_model, .messaging => true,
    };
}

/// The availability of a capability given the current network state.
///
/// While online everything is full. Offline, on-device capabilities stay full; cloud sync and
/// the remote model become unavailable because their work lives elsewhere; messaging degrades,
/// queuing to send when a connection returns so the person can still act.
pub fn availability(capability: Capability, online: bool) Availability {
    if (online) return .full;
    return switch (capability) {
        .on_device_agent, .local_files, .camera => .full,
        .messaging => .degraded,
        .cloud_sync, .remote_model => .unavailable,
    };
}

test "on-device capabilities stay fully available offline" {
    try std.testing.expectEqual(Availability.full, availability(.on_device_agent, false));
    try std.testing.expectEqual(Availability.full, availability(.local_files, false));
    try std.testing.expectEqual(Availability.full, availability(.camera, false));
}

test "cloud capabilities become unavailable offline" {
    try std.testing.expectEqual(Availability.unavailable, availability(.cloud_sync, false));
    try std.testing.expectEqual(Availability.unavailable, availability(.remote_model, false));
}

test "messaging degrades to queue-and-send-later offline" {
    try std.testing.expectEqual(Availability.degraded, availability(.messaging, false));
}

test "everything is fully available while online" {
    for (std.enums.values(Capability)) |capability| {
        try std.testing.expectEqual(Availability.full, availability(capability, true));
    }
}

test "a network-bound capability is never full while offline, swept" {
    // The offline-honesty property: nothing that needs the network claims to work in full when
    // the network is gone.
    for (std.enums.values(Capability)) |capability| {
        if (needsNetwork(capability)) {
            try std.testing.expect(availability(capability, false) != .full);
        }
    }
}
