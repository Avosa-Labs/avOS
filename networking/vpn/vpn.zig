//! Deciding where each packet may go when a tunnel is meant to carry the
//! device's traffic, so a dropped tunnel leaks nothing to the clear network.
//!
//! A VPN is a promise: this traffic travels inside the tunnel and nowhere else.
//! The promise is easy to keep while the tunnel is up and almost always broken the
//! moment it drops, because the default behaviour of every network stack is to
//! fall back to the clear path — which is exactly the traffic the tunnel existed
//! to hide, now sent in the open at the worst possible moment. The feature that
//! keeps the promise is a kill switch: when the tunnel is not up, traffic that was
//! meant to be tunnelled is blocked rather than sent clear. The only exceptions are
//! the packets that never needed the tunnel — loopback that never leaves the
//! device — and the packets to the tunnel endpoint itself, which must go clear
//! because they are how the tunnel is built.
//!
//! This module routes no packets. It decides, for a destination and the current
//! tunnel state, whether a packet goes through the tunnel, goes clear, or is
//! blocked, as a pure function whose central property is that under a full-tunnel
//! policy no general-internet packet is ever routed clear, up or down.

const std = @import("std");

/// How the device is configured to use the tunnel.
pub const Policy = enum {
    /// All traffic goes through the tunnel. When the tunnel is down, tunnelled
    /// traffic is blocked, never sent clear. This is the kill switch.
    full_tunnel,
    /// Only some traffic goes through the tunnel; named destinations are allowed
    /// on the clear path. Traffic that should be tunnelled is still blocked when
    /// the tunnel is down.
    split_tunnel,
};

/// The current state of the tunnel.
pub const TunnelState = enum {
    /// Established and carrying traffic.
    up,
    /// Not established: connecting, dropped, or never started. Traffic that needs
    /// the tunnel cannot use it.
    down,

    fn isUp(state: TunnelState) bool {
        return state == .up;
    }
};

/// A class of destination, coarse enough to route without enumerating hosts.
pub const DestinationClass = enum {
    /// The tunnel endpoint itself. Its packets must travel clear, because they are
    /// how the tunnel is established; tunnelling them would be circular.
    tunnel_endpoint,
    /// The device itself, over loopback. Never leaves the device, so the tunnel is
    /// irrelevant to it.
    loopback,
    /// The local network: other devices on the same segment. Whether these are
    /// allowed clear is a policy choice.
    local_network,
    /// Any general destination out on the internet: the traffic the tunnel exists
    /// to protect.
    general,
};

/// A destination a packet is bound for.
pub const Destination = struct {
    class: DestinationClass,
    /// In split-tunnel mode, whether this destination is one of those allowed to
    /// take the clear path. Ignored under a full tunnel.
    split_allows_clear: bool = false,
};

/// Where a packet is routed.
pub const Route = enum {
    /// Through the tunnel.
    tunnel,
    /// On the clear network, outside the tunnel.
    clear,
    /// Dropped: it may not travel by either path right now.
    blocked,
};

/// How the tunnel treats the local network: some deployments allow reaching local
/// devices (a printer, a NAS) off-tunnel, others forbid it to prevent a local
/// pivot.
pub const LocalAccess = enum {
    /// Local-network traffic may go clear.
    allowed,
    /// Local-network traffic is blocked from the clear path, keeping everything
    /// the person does inside the tunnel.
    blocked,
};

/// The tunnel configuration a routing decision is made against.
pub const Config = struct {
    policy: Policy,
    local_access: LocalAccess = .blocked,
};

/// Decides where a packet to a destination is routed, given the config and tunnel
/// state.
///
/// Loopback always goes clear: it never leaves the device. The tunnel endpoint
/// always goes clear: its packets build the tunnel and cannot travel inside it.
/// For everything else the kill switch governs — general traffic goes through the
/// tunnel when it is up and is blocked when it is down, and is never sent clear
/// under a full-tunnel policy. Under split tunnel, a destination explicitly allowed
/// clear takes the clear path; anything else follows the same tunnel-or-block rule.
/// Local-network traffic follows the configured local-access choice while the
/// tunnel is up and is blocked when it is down unless allowed clear.
pub fn route(config: Config, state: TunnelState, dest: Destination) Route {
    switch (dest.class) {
        // Never leaves the device; the tunnel does not apply.
        .loopback => return .clear,
        // The packets that build the tunnel must travel outside it.
        .tunnel_endpoint => return .clear,
        .local_network => {
            if (config.local_access == .allowed) return .clear;
            // Not allowed clear: it would have to be tunnelled, and only when up.
            return if (state.isUp()) .tunnel else .blocked;
        },
        .general => {
            if (config.policy == .split_tunnel and dest.split_allows_clear) return .clear;
            // Full tunnel, or split-tunnel traffic not on the clear list: tunnel
            // when up, block when down. Never clear.
            return if (state.isUp()) .tunnel else .blocked;
        },
    }
}

fn general(split_clear: bool) Destination {
    return .{ .class = .general, .split_allows_clear = split_clear };
}

const loopback: Destination = .{ .class = .loopback };
const endpoint: Destination = .{ .class = .tunnel_endpoint };
const local: Destination = .{ .class = .local_network };

test "loopback always goes clear regardless of policy or state" {
    for ([_]Policy{ .full_tunnel, .split_tunnel }) |policy| {
        for ([_]TunnelState{ .up, .down }) |state| {
            try std.testing.expectEqual(Route.clear, route(.{ .policy = policy }, state, loopback));
        }
    }
}

test "the tunnel endpoint always goes clear, since its packets build the tunnel" {
    try std.testing.expectEqual(Route.clear, route(.{ .policy = .full_tunnel }, .down, endpoint));
    try std.testing.expectEqual(Route.clear, route(.{ .policy = .full_tunnel }, .up, endpoint));
}

test "general traffic goes through the tunnel when it is up" {
    try std.testing.expectEqual(
        Route.tunnel,
        route(.{ .policy = .full_tunnel }, .up, general(false)),
    );
}

test "the kill switch blocks general traffic when the tunnel is down" {
    // The whole point: no clear fallback when the tunnel drops.
    try std.testing.expectEqual(
        Route.blocked,
        route(.{ .policy = .full_tunnel }, .down, general(false)),
    );
}

test "split tunnel lets an allowed destination take the clear path" {
    try std.testing.expectEqual(
        Route.clear,
        route(.{ .policy = .split_tunnel }, .up, general(true)),
    );
}

test "split-tunnel traffic not on the clear list still obeys the kill switch" {
    try std.testing.expectEqual(
        Route.blocked,
        route(.{ .policy = .split_tunnel }, .down, general(false)),
    );
    try std.testing.expectEqual(
        Route.tunnel,
        route(.{ .policy = .split_tunnel }, .up, general(false)),
    );
}

test "local access allowed sends local traffic clear" {
    const config: Config = .{ .policy = .full_tunnel, .local_access = .allowed };
    try std.testing.expectEqual(Route.clear, route(config, .up, local));
    try std.testing.expectEqual(Route.clear, route(config, .down, local));
}

test "local access blocked tunnels local traffic and blocks it when down" {
    const config: Config = .{ .policy = .full_tunnel, .local_access = .blocked };
    try std.testing.expectEqual(Route.tunnel, route(config, .up, local));
    try std.testing.expectEqual(Route.blocked, route(config, .down, local));
}

test "under a full tunnel no general packet is ever routed clear, swept" {
    // The leak-prevention invariant. Across every state, a full-tunnel general
    // packet is tunnelled or blocked, never clear — even one flagged clear, since
    // the flag is a split-tunnel notion the full-tunnel path ignores.
    for ([_]TunnelState{ .up, .down }) |state| {
        for ([_]LocalAccess{ .allowed, .blocked }) |local_access| {
            for ([_]bool{ false, true }) |flagged| {
                const config: Config = .{ .policy = .full_tunnel, .local_access = local_access };
                const r = route(config, state, general(flagged));
                try std.testing.expect(r != .clear);
            }
        }
    }
}

test "a split-tunnel general packet is only clear when explicitly allowed, swept" {
    // Even under split tunnel, a general packet not on the clear list is never
    // sent clear.
    for ([_]TunnelState{ .up, .down }) |state| {
        const r = route(.{ .policy = .split_tunnel }, state, general(false));
        try std.testing.expect(r != .clear);
    }
}
