//! Home, agent-native: the capabilities a person's devices are read and controlled through, over the
//! real home domain. Listing devices and reading a device's state are silent; turning a light or plug
//! on or off, and locking a lock, are local changes; unlocking a lock lowers a physical barrier and is
//! held for the person.
//!
//! This module declares the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the real devices.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "home.list", .required_capability = "home.read", .effect = .read_only },
    .{ .name = "home.status", .required_capability = "home.read", .effect = .read_only },
    .{ .name = "home.set", .required_capability = "home.control", .effect = .local_mutation },
    .{ .name = "home.unlock", .required_capability = "home.unlock", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Home", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading and controlling devices are unheld; only unlocking a lock is held" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        try testing.expectEqual(std.mem.eql(u8, tool.name, "home.unlock"), held);
    }
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
