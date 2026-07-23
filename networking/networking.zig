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
pub const http = @import("http/http.zig");
pub const reachability = @import("reachability/reachability.zig");
pub const stack = @import("stack/stack.zig");

test {
    _ = captive_portal;
    _ = dns;
    _ = firewall;
    _ = http;
    _ = reachability;
    _ = stack;
}
