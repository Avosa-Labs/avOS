//! Store, agent-native: the capabilities apps are discovered and installed through, over
//! the real store domain, with installing held and every install traced to its source.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Source = domain.Source;
pub const installNeedsAcknowledgement = domain.installNeedsAcknowledgement;

pub const tools = [_]framework.Tool{
    .{ .name = "store.browse", .required_capability = "store.browse", .effect = .read_only },
    .{ .name = "store.details", .required_capability = "store.browse", .effect = .read_only },
    .{ .name = "store.install", .required_capability = "store.install", .effect = .value_transfer },
    .{ .name = "store.update", .required_capability = "store.install", .effect = .local_mutation },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Store", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;
test "a sideloaded install always needs an explicit acknowledgement" {
    try testing.expect(installNeedsAcknowledgement(.sideload));
    try testing.expect(!installNeedsAcknowledgement(.store));
}
test "installing is value-transfer and held for the person" {
    try testing.expect(tools[2].effect.needsApproval());
}
