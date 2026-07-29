//! Wallet, agent-native: the capabilities a person's cards and money are kept and spent through, over
//! the real wallet domain. Listing cards and reading the balance are silent; adding a card is a local
//! change; a payment moves money, so it carries the strongest effect the frame knows — value transfer —
//! and is held for the person and applied exactly once.
//!
//! This module declares the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the real cards and balance.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

pub const tools = [_]framework.Tool{
    .{ .name = "wallet.list", .required_capability = "wallet.read", .effect = .read_only },
    .{ .name = "wallet.balance", .required_capability = "wallet.read", .effect = .read_only },
    .{ .name = "wallet.add_card", .required_capability = "wallet.write", .effect = .local_mutation },
    .{ .name = "wallet.pay", .required_capability = "wallet.pay", .effect = .value_transfer },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Wallet", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading is silent, adding a card is local, and only paying transfers value and is held" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        try testing.expectEqual(std.mem.eql(u8, tool.name, "wallet.pay"), held);
    }
    // Paying is the strongest effect, distinct from an ordinary external act.
    try testing.expectEqual(framework.Effect.value_transfer, tools[3].effect);
    try testing.expectEqual(framework.Effect.read_only, tools[0].effect);
}
