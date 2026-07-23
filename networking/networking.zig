//! Reaching the network, and deciding who may.
//!
//! The modules here decide rather than transmit: which transport a request
//! should take given what is reachable and what it costs, and whether a
//! principal may open a connection at all. Moving packets is the stack's job,
//! below these; what lives here is the policy that governs it, testable without
//! a network.

pub const captive_portal = @import("captive-portal/captive_portal.zig");
pub const dns = @import("dns/dns.zig");
pub const firewall = @import("firewall/firewall.zig");
pub const hotspot = @import("hotspot/hotspot.zig");
pub const http = @import("http/http.zig");
pub const quic = @import("quic/quic.zig");
pub const reachability = @import("reachability/reachability.zig");
pub const stack = @import("stack/stack.zig");
pub const vpn = @import("vpn/vpn.zig");
pub const websocket = @import("websocket/websocket.zig");

test {
    _ = captive_portal;
    _ = dns;
    _ = firewall;
    _ = hotspot;
    _ = http;
    _ = quic;
    _ = reachability;
    _ = stack;
    _ = vpn;
    _ = websocket;
}
