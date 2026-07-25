//! Store, agent-native: the capabilities apps are discovered and installed through,
//! with installing held for the person and every install traced to its source.
//!
//! Browsing and reading a listing are reads an agent does; installing adds code to the
//! device and is value-transfer, held for the person. The capabilities are declared for
//! discovery. Every install carries its source: a Store app is verified and signed,
//! while a sideloaded package is not, and installing it is an explicit, acknowledged
//! act.
//!
//! This module defines the app's capabilities and its source rule; the shared frame
//! gates and records.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const tools = [_]framework.Tool{
    .{ .name = "store.browse", .required_capability = "store.browse", .effect = .read_only },
    .{ .name = "store.details", .required_capability = "store.browse", .effect = .read_only },
    .{ .name = "store.install", .required_capability = "store.install", .effect = .value_transfer },
    .{ .name = "store.update", .required_capability = "store.install", .effect = .local_mutation },
};

const domain = @import("domain.zig");
pub const Store = domain.Store;
pub const App = framework.App;

/// Assembles the store app over the shared frame: its domain, its registered
/// capabilities, and the ledger every operation is recorded to. Both the human surface
/// and an agent reach the one domain through this app.
pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "store", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}


/// Where an install came from.
pub const Source = enum { store, sideload };

/// Whether an install from a source needs an explicit acknowledgement. A sideload
/// always does; a Store install is verified.
pub fn installNeedsAcknowledgement(source: Source) bool {
    return source == .sideload;
}

const testing = std.testing;

test "a sideloaded install always needs an explicit acknowledgement" {
    try testing.expect(installNeedsAcknowledgement(.sideload));
    try testing.expect(!installNeedsAcknowledgement(.store));
}

test "installing is value-transfer and held for the person" {
    try testing.expect(tools[2].effect.needsApproval());
}
