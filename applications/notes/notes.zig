//! Notes, agent-native: the capabilities a person's notebook is written and read through, over the
//! real notes domain. Listing and reading are silent; creating and editing are local changes; deleting
//! a note is irreversible and held for the person.
//!
//! This module declares the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the real notes.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "note.list", .required_capability = "notes.read", .effect = .read_only },
    .{ .name = "note.read", .required_capability = "notes.read", .effect = .read_only },
    .{ .name = "note.create", .required_capability = "notes.write", .effect = .local_mutation },
    .{ .name = "note.edit", .required_capability = "notes.write", .effect = .local_mutation },
    .{ .name = "note.pin", .required_capability = "notes.write", .effect = .local_mutation },
    .{ .name = "note.delete", .required_capability = "notes.write", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Notes", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading is silent, writing is local, and deleting is held" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        try testing.expectEqual(std.mem.eql(u8, tool.name, "note.delete"), held);
    }
    // The notebook offers a silent read so an agent can look before it acts.
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
