//! Photos, agent-native: the capabilities a person's photo library is organised and read through, over
//! the real photos domain. Listing and viewing are silent; importing, favouriting, and filing into an
//! album are local changes; sharing a photo leaves the device and is held for the person.
//!
//! This module declares the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the real library.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "photo.list", .required_capability = "photos.read", .effect = .read_only },
    .{ .name = "photo.view", .required_capability = "photos.read", .effect = .read_only },
    .{ .name = "photo.import", .required_capability = "photos.write", .effect = .local_mutation },
    .{ .name = "photo.favorite", .required_capability = "photos.write", .effect = .local_mutation },
    .{ .name = "photo.album", .required_capability = "photos.write", .effect = .local_mutation },
    .{ .name = "photo.share", .required_capability = "photos.share", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Photos", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading and organising are unheld; only sharing a photo is held" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        try testing.expectEqual(std.mem.eql(u8, tool.name, "photo.share"), held);
    }
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
