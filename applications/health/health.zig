//! Health, agent-native: the capabilities a person's private readings are recorded and read through,
//! over the real health domain. Reading the log and a summary are silent; recording a reading is a
//! local change; sharing a summary leaves the device and is held for the person. The app's data is
//! on-device-only — the most private class — so an agent reads it in place, never off the device
//! without the person's approval on a share.
//!
//! This module declares the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the real readings.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

/// Health data is the person's private world: it never leaves the device without a per-use grant.
pub const data_privacy = framework.DataPrivacy.on_device;

pub const tools = [_]framework.Tool{
    .{ .name = "health.log", .required_capability = "health.read", .effect = .read_only },
    .{ .name = "health.summary", .required_capability = "health.read", .effect = .read_only },
    .{ .name = "health.record", .required_capability = "health.write", .effect = .local_mutation },
    .{ .name = "health.share", .required_capability = "health.share", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Health", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading is silent, recording is local, and only sharing a summary is held" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        try testing.expectEqual(std.mem.eql(u8, tool.name, "health.share"), held);
    }
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
    // The app's data never leaves the device on its own.
    try testing.expect(!data_privacy.mayLeaveDevice());
}
