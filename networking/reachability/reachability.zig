//! What the device can currently reach, and how much a connection is worth
//! trusting or spending on.
//!
//! Reachability is not a boolean. A device may be on wifi that is captive and
//! leads nowhere until a login page is cleared, on cellular that costs money per
//! megabyte, or on both at once with a choice to make. Software that treats "has
//! an interface" as "can reach the internet" fails in exactly the cases that
//! matter: it downloads a gigabyte over a metered link, or hangs waiting on a
//! captive network that will never answer. So reachability is a small set of
//! facts about each transport, and a decision about which transport a given kind
//! of traffic should use.
//!
//! This module holds those facts and that decision. It moves no packets; it
//! records the state of each transport and answers which one a request should
//! take, or that none can serve it. The decision is logic, testable across
//! network conditions a real radio would have to be physically placed in to
//! reproduce.

const std = @import("std");

/// A way the device can reach the network.
pub const Transport = enum {
    /// Wireless local network. Usually unmetered and fast, but may be captive.
    wifi,
    /// Cellular. Usually works anywhere but often metered.
    cellular,
    /// Wired, through an accessory. Unmetered and reliable when present.
    ethernet,

    pub const count = std.enums.values(Transport).len;
};

/// The state of one transport.
pub const Link = struct {
    /// Whether the transport has a connection at the link layer at all.
    connected: bool = false,
    /// Whether it has actually reached the internet, confirmed by a
    /// reachability probe. A connected link that has not confirmed may be
    /// captive.
    internet_confirmed: bool = false,
    /// Whether it is behind a captive portal that must be cleared first.
    captive: bool = false,
    /// Whether using it costs the person money by the byte.
    metered: bool = false,

    /// Whether this link can carry ordinary traffic right now.
    ///
    /// It must be connected, have confirmed internet, and not be stuck behind a
    /// captive portal. A connected-but-captive link is worse than useless for a
    /// background request, because it will answer with a login page rather than
    /// the data asked for.
    pub fn isUsable(link: Link) bool {
        return link.connected and link.internet_confirmed and !link.captive;
    }
};

/// What a request is willing to tolerate, so the right transport is chosen for
/// it.
pub const Requirement = enum {
    /// Interactive, small, and worth using a metered link for: a message, a
    /// command. Takes the best usable link, metered or not.
    interactive,
    /// Bulk and deferrable: a backup, a large download, a model update. Must not
    /// run on a metered link, because the person did not agree to pay for it.
    unmetered_only,
    /// Background and low-value: prefetching, telemetry. Runs only on an
    /// unmetered link and yields entirely when none is free.
    background,
};

/// Why no transport was chosen.
pub const Refusal = enum {
    /// No transport is usable at all.
    offline,
    /// A usable transport exists, but only a metered one, and the request will
    /// not use metered links.
    would_be_metered,
    /// A transport is connected but stuck behind a captive portal.
    captive_only,
};

/// The chosen transport, or why none was.
pub const Decision = union(enum) {
    use: Transport,
    hold: Refusal,

    pub fn hasTransport(decision: Decision) bool {
        return decision == .use;
    }
};

/// The device's whole reachability state.
pub const Reachability = struct {
    links: [Transport.count]Link = @splat(.{}),

    pub fn linkOf(reachability: Reachability, transport: Transport) Link {
        return reachability.links[@intFromEnum(transport)];
    }

    pub fn setLink(reachability: *Reachability, transport: Transport, link: Link) void {
        reachability.links[@intFromEnum(transport)] = link;
    }

    /// Whether the device can reach the internet at all, on any transport.
    pub fn isOnline(reachability: Reachability) bool {
        for (std.enums.values(Transport)) |transport| {
            if (reachability.linkOf(transport).isUsable()) return true;
        }
        return false;
    }

    /// Chooses a transport for a request.
    ///
    /// Prefers the cheapest usable transport that meets the requirement:
    /// unmetered before metered, and among equals the order ethernet, wifi,
    /// cellular, which runs cheapest and most reliable first. A request that
    /// forbids metered links is held rather than quietly costing the person
    /// money, and the refusal distinguishes offline from metered-only from
    /// captive so a caller can tell the person something true.
    pub fn choose(reachability: Reachability, requirement: Requirement) Decision {
        var best_metered: ?Transport = null;
        var saw_captive = false;

        // Preference order: ethernet, wifi, cellular.
        for ([_]Transport{ .ethernet, .wifi, .cellular }) |transport| {
            const link = reachability.linkOf(transport);
            if (link.connected and link.captive) saw_captive = true;

            if (!link.isUsable()) continue;

            if (!link.metered) {
                // The best case: an unmetered usable link, taken immediately in
                // preference order.
                return .{ .use = transport };
            }
            // Remember the first usable metered link in case nothing unmetered
            // turns up.
            if (best_metered == null) best_metered = transport;
        }

        // No unmetered link. A metered one serves an interactive request but not
        // the deferrable kinds.
        if (best_metered) |transport| {
            if (requirement == .interactive) return .{ .use = transport };
            return .{ .hold = .would_be_metered };
        }

        // Nothing usable. Say why as precisely as the state allows: a captive
        // portal is a different problem to solve than being offline.
        if (saw_captive) return .{ .hold = .captive_only };
        return .{ .hold = .offline };
    }
};

const usable_unmetered: Link = .{ .connected = true, .internet_confirmed = true };
const usable_metered: Link = .{ .connected = true, .internet_confirmed = true, .metered = true };
const captive: Link = .{ .connected = true, .captive = true };

test "an unmetered link is chosen for any requirement" {
    var reachability: Reachability = .{};
    reachability.setLink(.wifi, usable_unmetered);
    for (std.enums.values(Requirement)) |requirement| {
        try std.testing.expectEqual(Decision{ .use = .wifi }, reachability.choose(requirement));
    }
}

test "ethernet is preferred over wifi over cellular" {
    var reachability: Reachability = .{};
    reachability.setLink(.wifi, usable_unmetered);
    reachability.setLink(.cellular, usable_unmetered);
    reachability.setLink(.ethernet, usable_unmetered);
    // Cheapest and most reliable first.
    try std.testing.expectEqual(Decision{ .use = .ethernet }, reachability.choose(.interactive));

    reachability.setLink(.ethernet, .{});
    try std.testing.expectEqual(Decision{ .use = .wifi }, reachability.choose(.interactive));
}

test "a metered link serves interactive traffic but not bulk" {
    var reachability: Reachability = .{};
    reachability.setLink(.cellular, usable_metered);

    try std.testing.expectEqual(Decision{ .use = .cellular }, reachability.choose(.interactive));
    // A backup must not silently cost the person money.
    try std.testing.expectEqual(Decision{ .hold = .would_be_metered }, reachability.choose(.unmetered_only));
    try std.testing.expectEqual(Decision{ .hold = .would_be_metered }, reachability.choose(.background));
}

test "an unmetered link is preferred over a metered one even out of order" {
    var reachability: Reachability = .{};
    // Cellular is metered; wifi is unmetered. Wifi wins for bulk despite cellular
    // being present.
    reachability.setLink(.cellular, usable_metered);
    reachability.setLink(.wifi, usable_unmetered);
    try std.testing.expectEqual(Decision{ .use = .wifi }, reachability.choose(.unmetered_only));
}

test "a captive link is not usable and is reported as captive" {
    var reachability: Reachability = .{};
    reachability.setLink(.wifi, captive);
    // Connected but leads only to a login page.
    try std.testing.expect(!reachability.linkOf(.wifi).isUsable());
    try std.testing.expectEqual(Decision{ .hold = .captive_only }, reachability.choose(.interactive));
}

test "a connected link that has not confirmed internet is not usable" {
    var reachability: Reachability = .{};
    // Link up, but the reachability probe has not succeeded: it might be captive
    // or dead. Not usable until confirmed.
    reachability.setLink(.wifi, .{ .connected = true, .internet_confirmed = false });
    try std.testing.expect(!reachability.linkOf(.wifi).isUsable());
}

test "an offline device says offline" {
    const reachability: Reachability = .{};
    try std.testing.expect(!reachability.isOnline());
    try std.testing.expectEqual(Decision{ .hold = .offline }, reachability.choose(.interactive));
}

test "online reflects any usable transport" {
    var reachability: Reachability = .{};
    try std.testing.expect(!reachability.isOnline());
    reachability.setLink(.cellular, usable_metered);
    // A metered link still counts as online even if bulk traffic will not use it.
    try std.testing.expect(reachability.isOnline());
}

test "captive is distinguished from offline" {
    var reachability: Reachability = .{};
    reachability.setLink(.wifi, captive);
    // A person on a captive network needs to be told to clear the portal, not
    // that they are offline.
    try std.testing.expectEqual(Decision{ .hold = .captive_only }, reachability.choose(.background));

    reachability.setLink(.wifi, .{});
    try std.testing.expectEqual(Decision{ .hold = .offline }, reachability.choose(.background));
}

test "background traffic runs only on an unmetered link" {
    var reachability: Reachability = .{};
    reachability.setLink(.wifi, usable_unmetered);
    try std.testing.expectEqual(Decision{ .use = .wifi }, reachability.choose(.background));

    // Swap to metered: background yields.
    reachability.setLink(.wifi, usable_metered);
    try std.testing.expectEqual(Decision{ .hold = .would_be_metered }, reachability.choose(.background));
}

test "the requirement never causes a metered link to be picked for bulk" {
    // Swept: with only metered links up, no non-interactive requirement ever
    // chooses to spend the person's money.
    var reachability: Reachability = .{};
    reachability.setLink(.wifi, usable_metered);
    reachability.setLink(.cellular, usable_metered);
    try std.testing.expect(!reachability.choose(.unmetered_only).hasTransport());
    try std.testing.expect(!reachability.choose(.background).hasTransport());
}
