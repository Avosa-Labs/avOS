//! Browser, agent-native: the capabilities pages are opened, read, bookmarked, filled, and submitted,
//! and sites granted, through, over the real browser domain. Opening, bookmarking, and filling a form
//! field are ordinary local changes; reading the page is silent and returns only the engine's
//! projection; submitting a form and granting a site a sensitive permission are the consequential acts,
//! held for the person the same as any external effect.
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
    .{ .name = "browser.fill", .required_capability = "browser.open", .effect = .local_mutation },
    .{ .name = "browser.submit", .required_capability = "browser.submit", .effect = .external },
    .{ .name = "browser.grant_site", .required_capability = "browser.grant_site", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Browser", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "reading and filling are unheld; submitting a form and granting a site are held" {
    // Open, read, bookmark, and fill are not held; submit and grant_site reach off the device.
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        const consequential = std.mem.eql(u8, tool.name, "browser.submit") or std.mem.eql(u8, tool.name, "browser.grant_site");
        try testing.expectEqual(consequential, held);
    }
    try testing.expectEqual(framework.Effect.read_only, tools[1].effect); // read_page
}
