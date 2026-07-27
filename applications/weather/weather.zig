//! Weather, agent-native: the capabilities forecasts are read and locations saved through, over
//! the real weather domain. Reads are silent — they return external data an agent may retrieve
//! freely; saving a location and enabling an alert are ordinary local changes; nothing is
//! consequential, so Weather is the app that shows a read-mostly surface still gets the whole
//! framework without any held operation.
//!
//! This module defines the app's capabilities; the shared frame gates and records, and the domain
//! holds the state and reads through the connector.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Connector = domain.Connector;
pub const Deterministic = domain.Deterministic;

pub const tools = [_]framework.Tool{
    .{ .name = "weather.current", .required_capability = "weather.current", .effect = .read_only },
    .{ .name = "weather.forecast", .required_capability = "weather.forecast", .effect = .read_only },
    .{ .name = "weather.add_location", .required_capability = "weather.add_location", .effect = .local_mutation },
    .{ .name = "weather.enable_alert", .required_capability = "weather.enable_alert", .effect = .local_mutation },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Weather", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading weather is silent and no weather operation is consequential" {
    // Reads return external data; saving and alerts are local. None is held for the person.
    for (tools) |tool| try testing.expect(!tool.effect.needsApproval());
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
