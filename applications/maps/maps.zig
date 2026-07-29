//! Maps, agent-native: the capabilities a person's places are saved, measured, and shared through,
//! over the real maps domain. Listing places and reading a distance are silent; saving a place is a
//! local change; sharing a location leaves the device and is held for the person.
//!
//! This module declares the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the real places and computes distances on the device.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "maps.list", .required_capability = "maps.read", .effect = .read_only },
    .{ .name = "maps.distance", .required_capability = "maps.read", .effect = .read_only },
    .{ .name = "maps.save", .required_capability = "maps.write", .effect = .local_mutation },
    .{ .name = "maps.share_location", .required_capability = "maps.share", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Maps", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading and saving are unheld; only sharing a location is held" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        try testing.expectEqual(std.mem.eql(u8, tool.name, "maps.share_location"), held);
    }
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
