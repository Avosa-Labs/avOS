//! Keyboard, agent-native: the capabilities a person's text shortcuts and dictionary are read and
//! taught through, over the real keyboard domain. Reading the shortcuts and expanding a trigger are
//! silent; adding a shortcut and learning a word are local changes. Nothing reaches off the device, so
//! nothing is held.
//!
//! This module declares the app's capabilities; the shared frame gates and records, and the domain
//! holds the real shortcuts and learned words.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "keyboard.shortcuts", .required_capability = "keyboard.read", .effect = .read_only },
    .{ .name = "keyboard.expand", .required_capability = "keyboard.read", .effect = .read_only },
    .{ .name = "keyboard.add_shortcut", .required_capability = "keyboard.write", .effect = .local_mutation },
    .{ .name = "keyboard.learn", .required_capability = "keyboard.write", .effect = .local_mutation },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Keyboard", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading is silent, and a shortcut or a learned word is a local change, never held" {
    for (tools) |tool| {
        try testing.expect(!tool.effect.needsApproval());
    }
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
