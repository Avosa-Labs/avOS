//! Phone, agent-native: the capabilities calls are placed, answered, and screened
//! through, over the real phone domain, with dialling held and unknown callers screened.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Caller = domain.Caller;
pub const Screening = domain.Screening;
pub const ringsThrough = domain.ringsThrough;
pub const isEmergency = domain.isEmergency;

pub const tools = [_]framework.Tool{
    .{ .name = "call.history", .required_capability = "phone.read", .effect = .read_only },
    // Screening an unknown caller produces a transcript the person sees — a local change that
    // notifies, not a silent read.
    .{ .name = "call.screen", .required_capability = "phone.screen", .effect = .local_mutation },
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
test "screening notifies, dialling is held, history is a silent read" {
    try testing.expect(!tools[0].effect.needsApproval()); // call.history, silent read
    try testing.expectEqual(framework.Effect.local_mutation, tools[1].effect); // call.screen notifies
    try testing.expect(tools[2].effect.needsApproval()); // call.dial held
}

test "an emergency number is outside agent routing" {
    try testing.expect(isEmergency("112"));
    try testing.expect(isEmergency("911"));
    try testing.expect(!isEmergency("5551234"));
}
