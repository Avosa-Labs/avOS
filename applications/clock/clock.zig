//! Clock, agent-native: the capabilities a person's world clocks are kept and read through, over the
//! real clock domain. Listing and reading a local time are silent; adding and removing a world clock
//! are ordinary local changes. Nothing here is consequential — a clock reaches nothing outside the
//! device — so no operation is held.
//!
//! This module declares the app's capabilities; the shared frame gates and records, and the domain
//! holds the real world clocks and the zone arithmetic.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "clock.list", .required_capability = "clock.read", .effect = .read_only },
    .{ .name = "clock.time", .required_capability = "clock.read", .effect = .read_only },
    .{ .name = "clock.add", .required_capability = "clock.write", .effect = .local_mutation },
    .{ .name = "clock.remove", .required_capability = "clock.write", .effect = .local_mutation },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Clock", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading is silent, and keeping a world clock is a local change, never held" {
    for (tools) |tool| {
        try testing.expect(!tool.effect.needsApproval());
    }
    // A silent read so an agent can tell the time in a place before it acts on it.
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
