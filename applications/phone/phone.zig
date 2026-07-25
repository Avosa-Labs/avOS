//! Phone, agent-native: the capabilities calls are placed, answered, and screened
//! through, over the real phone domain, with dialling held and unknown callers screened.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Caller = domain.Caller;
pub const ringsThrough = domain.ringsThrough;

pub const tools = [_]framework.Tool{
    .{ .name = "call.history", .required_capability = "phone.read", .effect = .read_only },
    .{ .name = "call.screen", .required_capability = "phone.screen", .effect = .read_only },
    .{ .name = "call.dial", .required_capability = "phone.dial", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Phone", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;
test "an unknown, unverified caller is screened rather than ringing through" {
    try testing.expect(ringsThrough(.{ .known = true, .verified = false }));
    try testing.expect(!ringsThrough(.{ .known = false, .verified = false }));
}
test "dialling is external and held for the person" {
    try testing.expect(tools[2].effect.needsApproval());
}
