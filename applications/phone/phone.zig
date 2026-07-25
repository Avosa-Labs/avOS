//! Phone, agent-native: the capabilities calls are placed, answered, and screened
//! through, with dialling held for the person and an unverified caller screened first.
//!
//! Reading the history and running a screening check are reads an agent does; placing a
//! call is external and held; answering is the person's. The capabilities are declared
//! for discovery. The screening rule stays: a call from an unknown, unverified number
//! is screened rather than rung through, because an unverified ring is how spam and
//! spoofing reach a person.
//!
//! This module defines the app's capabilities and its screening rule; the shared frame
//! gates and records.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const tools = [_]framework.Tool{
    .{ .name = "call.history", .required_capability = "phone.read", .effect = .read_only },
    .{ .name = "call.screen", .required_capability = "phone.screen", .effect = .read_only },
    .{ .name = "call.dial", .required_capability = "phone.dial", .effect = .external },
};

/// What is known about an incoming caller.
pub const Caller = struct { known: bool, verified: bool };

/// Whether an incoming call rings the person directly, or is screened first.
pub fn ringsThrough(caller: Caller) bool {
    return caller.known or caller.verified;
}

const testing = std.testing;

test "an unknown, unverified caller is screened rather than ringing through" {
    try testing.expect(ringsThrough(.{ .known = true, .verified = false }));
    try testing.expect(ringsThrough(.{ .known = false, .verified = true }));
    try testing.expect(!ringsThrough(.{ .known = false, .verified = false }));
}

test "dialling is external and held for the person" {
    try testing.expect(tools[2].effect.needsApproval());
}
