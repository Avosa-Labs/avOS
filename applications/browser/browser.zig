//! Browser, agent-native: the capabilities pages are opened, read, bookmarked, and sites granted
//! through, over the real browser domain. Opening and bookmarking are ordinary local changes; reading
//! the page is silent and returns only the engine's projection; granting a site a sensitive permission
//! is the one consequential act, held for the person the same as any external effect.
//!
//! This module defines the app's capabilities; the shared frame gates, holds, and records, and the
//! domain holds the state and reads through the engine.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Engine = domain.Engine;
pub const Deterministic = domain.Deterministic;
pub const Page = domain.Page;
pub const PageKind = domain.PageKind;
pub const Permission = domain.Permission;
pub const originOf = domain.originOf;

pub const tools = [_]framework.Tool{
    .{ .name = "browser.open", .required_capability = "browser.open", .effect = .local_mutation },
    .{ .name = "browser.read_page", .required_capability = "browser.read", .effect = .read_only },
    .{ .name = "browser.bookmark", .required_capability = "browser.bookmark", .effect = .local_mutation },
    .{ .name = "browser.grant_site", .required_capability = "browser.grant_site", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Browser", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading a page is silent and only granting a site is consequential" {
    // Open, read, and bookmark are not held; granting a site a sensitive permission is.
    try testing.expect(!tools[0].effect.needsApproval()); // open
    try testing.expect(!tools[1].effect.needsApproval()); // read_page
    try testing.expect(!tools[2].effect.needsApproval()); // bookmark
    try testing.expect(tools[3].effect.needsApproval()); // grant_site
    try testing.expectEqual(framework.Effect.read_only, tools[1].effect);
}
