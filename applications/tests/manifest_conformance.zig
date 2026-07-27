//! Confirms every default app's manifest declares exactly the capabilities the app
//! actually exports — so what an agent can discover in an app is what its package says
//! it can, never more and never less.
//!
//! A manifest is the app's public claim about itself: the capabilities it registers on
//! install. If that claim drifts from the tools the app really exports, the two halves
//! of the security story disagree — the package promises one surface and the running
//! app presents another, and an agent could discover an operation the manifest never
//! declared or fail to find one it did. This test pins them together: for each app, the
//! manifest's capability list and the tool set's names must be the same set, checked at
//! build time, so a capability added to an app without updating its manifest (or the
//! reverse) is a build error rather than a shipped inconsistency.

const std = @import("std");
const testing = std.testing;

const apps = @import("../applications.zig");

/// Asserts a manifest's declared capability names are exactly the app's tool names.
fn expectConforms(comptime manifest: anytype, tools: anytype) !void {
    try testing.expectEqual(@as(usize, tools.len), manifest.capabilities.len);
    // Every declared capability is an exported tool.
    inline for (manifest.capabilities) |declared| {
        var found = false;
        for (tools) |tool| {
            if (std.mem.eql(u8, tool.name, declared)) found = true;
        }
        try testing.expect(found);
    }
    // And every exported tool is declared.
    for (tools) |tool| {
        var declared = false;
        inline for (manifest.capabilities) |name| {
            if (std.mem.eql(u8, tool.name, name)) declared = true;
        }
        try testing.expect(declared);
    }
}

test "each default app's manifest declares exactly its exported capabilities" {
    try expectConforms(@import("../messages/manifest.zon"), apps.messages.tools);
    try expectConforms(@import("../calendar/manifest.zon"), apps.calendar.tools);
    try expectConforms(@import("../files/manifest.zon"), apps.files.tools);
    try expectConforms(@import("../camera/manifest.zon"), apps.camera.tools);
    try expectConforms(@import("../phone/manifest.zon"), apps.phone.tools);
    try expectConforms(@import("../contacts/manifest.zon"), apps.contacts.tools);
    try expectConforms(@import("../settings/manifest.zon"), apps.settings.tools);
    try expectConforms(@import("../store/manifest.zon"), apps.store.tools);
    try expectConforms(@import("../calculator/manifest.zon"), apps.calculator.tools);
    try expectConforms(@import("../agents/manifest.zon"), apps.agents.tools);
    try expectConforms(@import("../weather/manifest.zon"), apps.weather.tools);
}
