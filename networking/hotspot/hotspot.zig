//! Deciding whether the device shares its connection with another, so sharing
//! cannot quietly exhaust the uplink, spend the person's data, or let one guest
//! reach another.
//!
//! When a device becomes a hotspot it lends its uplink to other devices, and three
//! things that were implicit while it served only itself now need deciding. How
//! many clients may attach, because each one consumes the shared uplink and an
//! unbounded number degrades it for everyone including the host. Whether to share
//! at all when the uplink is metered, because a guest's download is spent from the
//! person's data allowance, not the guest's. And whether attached clients may
//! reach each other, because a hotspot's clients are strangers by default and one
//! guest probing another's device is a lateral attack the host enabled without
//! meaning to. None of these is the radio's decision; they are policy the host
//! makes on the person's behalf.
//!
//! This module carries no traffic and associates no client. It answers whether a
//! new client may attach given who is already attached and what the uplink costs,
//! and whether traffic between two attached clients is allowed, as pure decisions
//! over the hotspot's configuration and current client set.

const std = @import("std");

/// What the shared uplink costs, which decides whether sharing spends the person's
/// money.
pub const Uplink = enum {
    /// Unmetered: sharing costs nothing by the byte.
    unmetered,
    /// Metered: every byte a guest sends or receives is spent from the person's
    /// allowance.
    metered,
};

/// The host's choice about sharing a metered uplink.
pub const MeteredSharing = enum {
    /// The person has agreed to share even a metered uplink.
    allowed,
    /// Metered sharing is refused, so a guest cannot spend the person's data.
    refused,
};

/// Whether attached clients may talk to each other.
pub const ClientIsolation = enum {
    /// Clients are isolated: each may reach the uplink but not the others. The
    /// safe default for a hotspot of strangers.
    isolated,
    /// Clients may reach each other: appropriate only when the host knows every
    /// client is trusted, such as tethering the person's own devices.
    open,
};

/// The hotspot configuration a decision is made against.
pub const Config = struct {
    /// The most clients that may be attached at once. Each consumes the shared
    /// uplink; the cap keeps a crowd from degrading it for everyone.
    max_clients: u32,
    uplink: Uplink,
    metered_sharing: MeteredSharing = .refused,
    isolation: ClientIsolation = .isolated,
};

/// Why a client was refused attachment.
pub const AttachRefusal = enum {
    /// The client cap is reached; attaching another would degrade the uplink for
    /// those already on it.
    at_capacity,
    /// The uplink is metered and the person has not agreed to share it, so a guest
    /// cannot spend their data.
    metered_not_shared,
};

/// The outcome of an attachment attempt.
pub const AttachDecision = union(enum) {
    attach,
    refuse: AttachRefusal,

    pub fn attached(decision: AttachDecision) bool {
        return decision == .attach;
    }
};

/// Decides whether a new client may attach, given how many are already attached.
///
/// A metered uplink the person has not agreed to share refuses every client, so a
/// guest never spends the person's allowance without consent. Otherwise the client
/// cap governs: while there is room a client attaches, and at the cap another is
/// refused so the shared uplink is not degraded for those already using it. The
/// metered check comes first, because there is no point counting toward a cap on a
/// hotspot that may not share at all.
pub fn admitClient(config: Config, currently_attached: u32) AttachDecision {
    if (config.uplink == .metered and config.metered_sharing == .refused) {
        return .{ .refuse = .metered_not_shared };
    }
    if (currently_attached >= config.max_clients) {
        return .{ .refuse = .at_capacity };
    }
    return .attach;
}

/// Whether traffic from one attached client to another is allowed.
///
/// Only when the host has explicitly opened the hotspot to inter-client traffic.
/// The default is isolation, because a hotspot's clients are strangers and one
/// reaching another is a lateral move the host did not intend to permit.
pub fn allowClientToClient(config: Config) bool {
    return config.isolation == .open;
}

test "a client attaches while there is room on an unmetered uplink" {
    const config: Config = .{ .max_clients = 4, .uplink = .unmetered };
    try std.testing.expect(admitClient(config, 0).attached());
    try std.testing.expect(admitClient(config, 3).attached());
}

test "the client cap refuses attachment when full" {
    const config: Config = .{ .max_clients = 4, .uplink = .unmetered };
    try std.testing.expectEqual(
        AttachDecision{ .refuse = .at_capacity },
        admitClient(config, 4),
    );
}

test "a metered uplink not agreed for sharing refuses every client" {
    const config: Config = .{ .max_clients = 4, .uplink = .metered, .metered_sharing = .refused };
    try std.testing.expectEqual(
        AttachDecision{ .refuse = .metered_not_shared },
        admitClient(config, 0),
    );
}

test "a metered uplink the person agreed to share attaches within the cap" {
    const config: Config = .{ .max_clients = 2, .uplink = .metered, .metered_sharing = .allowed };
    try std.testing.expect(admitClient(config, 0).attached());
    try std.testing.expect(admitClient(config, 1).attached());
    try std.testing.expectEqual(
        AttachDecision{ .refuse = .at_capacity },
        admitClient(config, 2),
    );
}

test "the metered consent is checked before the cap" {
    // A full metered hotspot that may not share reports the sharing refusal, the
    // more informative cause: sharing is off entirely, not merely full.
    const config: Config = .{ .max_clients = 0, .uplink = .metered, .metered_sharing = .refused };
    try std.testing.expectEqual(
        AttachDecision{ .refuse = .metered_not_shared },
        admitClient(config, 0),
    );
}

test "clients are isolated by default" {
    const config: Config = .{ .max_clients = 4, .uplink = .unmetered };
    try std.testing.expect(!allowClientToClient(config));
}

test "inter-client traffic is allowed only when the hotspot is opened" {
    const open: Config = .{ .max_clients = 4, .uplink = .unmetered, .isolation = .open };
    try std.testing.expect(allowClientToClient(open));
    const isolated: Config = .{ .max_clients = 4, .uplink = .unmetered, .isolation = .isolated };
    try std.testing.expect(!allowClientToClient(isolated));
}

test "no client ever attaches beyond the cap, swept" {
    // Across a range of attached counts on a shareable uplink, attachment is
    // permitted exactly while below the cap.
    const config: Config = .{ .max_clients = 5, .uplink = .unmetered };
    var attached: u32 = 0;
    while (attached <= 10) : (attached += 1) {
        const decision = admitClient(config, attached);
        if (attached < config.max_clients) {
            try std.testing.expect(decision.attached());
        } else {
            try std.testing.expectEqual(AttachDecision{ .refuse = .at_capacity }, decision);
        }
    }
}

test "a guest never spends the person's data without consent, swept" {
    // The property: on a metered uplink not agreed for sharing, no attached count
    // ever admits a client.
    const config: Config = .{ .max_clients = 8, .uplink = .metered, .metered_sharing = .refused };
    var attached: u32 = 0;
    while (attached <= 8) : (attached += 1) {
        try std.testing.expect(!admitClient(config, attached).attached());
    }
}
