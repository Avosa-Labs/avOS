//! Tasks, agent-native: the capabilities a person's to-do list is kept through, over the real tasks
//! domain. Listing is silent; adding and completing are local changes; clearing a task is held.
//!
//! This module declares the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the real tasks.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "task.list", .required_capability = "tasks.read", .effect = .read_only },
    .{ .name = "task.add", .required_capability = "tasks.write", .effect = .local_mutation },
    .{ .name = "task.complete", .required_capability = "tasks.write", .effect = .local_mutation },
    .{ .name = "task.clear", .required_capability = "tasks.write", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Tasks", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "listing is silent, adding and completing are local, clearing is held" {
    for (tools) |tool| {
        try testing.expectEqual(std.mem.eql(u8, tool.name, "task.clear"), tool.effect.needsApproval());
    }
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
