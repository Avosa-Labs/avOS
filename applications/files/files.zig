//! Files, agent-native: the capabilities the file tree is browsed and organized
//! through, over the real files domain, with sharing held and every access confined to
//! its grant.
//!
//! Listing and opening are reads an agent does; editing, moving, and deleting are local
//! changes; sharing sends a file outside the device and is held for the person. The
//! capabilities are declared here for discovery, and each reaches the one domain that
//! holds the real tree and enforces the grant confinement.
//!
//! This module defines the app's capabilities; the domain holds the tree and its rules.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

/// Whether a path stays within the granted folder. Re-exported from the domain, which
/// enforces it on every operation.
pub const withinGrant = domain.withinGrant;

/// The capabilities Files exports for agents to discover and invoke.
pub const tools = [_]framework.Tool{
    .{ .name = "file.list", .required_capability = "files.read", .effect = .read_only },
    .{ .name = "file.open", .required_capability = "files.read", .effect = .read_only },
    .{ .name = "file.edit", .required_capability = "files.write", .effect = .local_mutation },
    .{ .name = "file.move", .required_capability = "files.write", .effect = .local_mutation },
    .{ .name = "file.share", .required_capability = "files.share", .effect = .external },
    .{ .name = "file.delete", .required_capability = "files.write", .effect = .local_mutation },
};

/// Assembles the Files app over the shared frame.
pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Files", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "the grant rule is enforced and re-exported from the domain" {
    try testing.expect(withinGrant("documents/notes.txt"));
    try testing.expect(!withinGrant("../other/secrets"));
}

test "sharing is external and held; listing and editing are the agent's" {
    try testing.expect(tools[4].effect.needsApproval());
    try testing.expect(!tools[0].effect.needsApproval());
    try testing.expect(!tools[2].effect.needsApproval());
}
