//! Music, agent-native: the capabilities a person's library is played and queued through, over the
//! real music domain. Listing the library and reading what is playing are silent; playing a track and
//! queueing one are local changes. Nothing here is consequential — music reaches nothing off the
//! device — so no operation is held.
//!
//! This module declares the app's capabilities; the shared frame gates and records, and the domain
//! holds the real library, the now-playing track, and the queue.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "music.list", .required_capability = "music.read", .effect = .read_only },
    .{ .name = "music.now_playing", .required_capability = "music.read", .effect = .read_only },
    .{ .name = "music.play", .required_capability = "music.control", .effect = .local_mutation },
    .{ .name = "music.queue", .required_capability = "music.control", .effect = .local_mutation },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Music", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading is silent, and playing or queueing is a local change, never held" {
    for (tools) |tool| {
        try testing.expect(!tool.effect.needsApproval());
    }
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
