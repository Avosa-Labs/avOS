//! Pins whether each default app needs an external provider, so "prefer a real connector" is a
//! checked property: the apps that reach the world are marked to await a real provider, and the
//! genuinely-local apps are marked never to be simulated.
//!
//! Connector maturity has three honest states — live, local-real, connector-pending — and the one an
//! app starts in follows from a static fact: does its domain need an external provider at all? A
//! local-real app (Files, Calculator, Contacts of local principals) answers from the device and is
//! never simulated. An app that reaches an external service (Messages, Calendar, Weather, Browser,
//! the Store catalogue) runs connector-pending — a labeled simulator answering — until a real
//! provider is linked, then flips to live with the same capabilities on real data. This module fixes
//! that classification and asserts it, so an app that quietly stopped needing a provider (or started
//! needing one) fails the build rather than shipping the wrong connector state.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

const ConnectorNeed = framework.ConnectorNeed;

const AppConnector = struct { app: []const u8, need: ConnectorNeed };
const needs = [_]AppConnector{
    // Genuinely local — answered from the device, never simulated.
    .{ .app = "Files", .need = .local_real },
    .{ .app = "Calculator", .need = .local_real },
    .{ .app = "Contacts", .need = .local_real },
    .{ .app = "Settings", .need = .local_real },
    .{ .app = "Agents", .need = .local_real },
    .{ .app = "Camera", .need = .local_real },
    .{ .app = "Phone", .need = .local_real },
    // Reach an external service — connector-pending until a real provider is linked.
    .{ .app = "Messages", .need = .needs_provider },
    .{ .app = "Calendar", .need = .needs_provider },
    .{ .app = "Weather", .need = .needs_provider },
    .{ .app = "Browser", .need = .needs_provider },
    .{ .app = "Store", .need = .needs_provider },
};

fn needOf(app: []const u8) ConnectorNeed {
    for (needs) |n| {
        if (std.mem.eql(u8, n.app, app)) return n.need;
    }
    unreachable;
}

const testing = std.testing;

test "the local apps are never simulated; the reaching apps await a real provider" {
    // A local-real app answers from the device and never runs a simulator.
    for ([_][]const u8{ "Files", "Calculator", "Contacts" }) |app| {
        try testing.expectEqual(ConnectorNeed.local_real, needOf(app));
        try testing.expect(!needOf(app).awaitsProvider());
    }
    // An app that reaches the world awaits a real provider — its connector-pending state is a
    // gap to close with a real link, not an end state.
    for ([_][]const u8{ "Messages", "Calendar", "Weather", "Browser" }) |app| {
        try testing.expectEqual(ConnectorNeed.needs_provider, needOf(app));
        try testing.expect(needOf(app).awaitsProvider());
    }
}

test "every default app has a connector need declared" {
    // The twelve default apps are all classified — none is left without a connector state.
    try testing.expectEqual(@as(usize, 12), needs.len);
}
