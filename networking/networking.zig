//! Reaching the network, and deciding who may.
//!
//! The modules here decide rather than transmit: which transport a request
//! should take given what is reachable and what it costs, and whether a
//! principal may open a connection at all. Moving packets is the stack's job,
//! below these; what lives here is the policy that governs it, testable without
//! a network.

pub const firewall = @import("firewall/firewall.zig");
pub const reachability = @import("reachability/reachability.zig");

test {
    _ = firewall;
    _ = reachability;
}
