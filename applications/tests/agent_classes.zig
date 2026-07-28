//! Pins the approval discipline every default app's agent door must follow, across all
//! twelve apps at once, so the class an agent's operation takes is a property of the
//! capability, checked at build time, not a convention each app is trusted to keep.
//!
//! The frame gives every capability one of a small set of effects, and the effect fixes
//! how an agent's call is handled: a read runs silently, a local change runs and notifies,
//! and a consequential effect — one that reaches outside the device or moves value — is
//! held for the person rather than run. Two properties must hold for every app for that
//! story to be true. A capability needs a person's approval exactly when its effect is
//! consequential, never by the caller's identity — so an agent and a person meet the same
//! gate. And every app offers at least one silent read, because an agent that cannot look
//! before it acts cannot act safely at all. Beyond those universals, the lightweight apps
//! (Weather, Calculator) prove the frame by holding nothing consequential, and the apps
//! that send, delete, or spend (Messages, Files, Store) always put at least one operation
//! behind a hold. This test reads the real tool tables and asserts all of it.

const std = @import("std");
const apps = @import("../applications.zig");
const framework = @import("../framework/agent_app.zig");

const Tool = framework.Tool;

fn silentReads(tools: []const Tool) usize {
    var n: usize = 0;
    for (tools) |tool| {
        if (tool.effect == .read_only) n += 1;
    }
    return n;
}

fn consequential(tools: []const Tool) usize {
    var n: usize = 0;
    for (tools) |tool| {
        if (tool.effect.needsApproval()) n += 1;
    }
    return n;
}

const testing = std.testing;

test "approval is a property of the effect, not the caller, in every app" {
    // For every capability of every app, a person's approval is required exactly when the
    // effect is consequential — the same gate an agent and a person meet.
    const tables = [_][]const Tool{
        &apps.agents.tools,   &apps.calculator.tools, &apps.calendar.tools,
        &apps.camera.tools,   &apps.contacts.tools,   &apps.files.tools,
        &apps.messages.tools, &apps.phone.tools,      &apps.settings.tools,
        &apps.store.tools,    &apps.weather.tools,    &apps.browser.tools,
    };
    for (tables) |tools| {
        for (tools) |tool| {
            const consequential_effect = tool.effect == .external or tool.effect == .value_transfer;
            try testing.expectEqual(consequential_effect, tool.effect.needsApproval());
        }
    }
}

test "every app offers at least one silent read, so an agent can look before it acts" {
    const tables = [_][]const Tool{
        &apps.agents.tools,   &apps.calculator.tools, &apps.calendar.tools,
        &apps.camera.tools,   &apps.contacts.tools,   &apps.files.tools,
        &apps.messages.tools, &apps.phone.tools,      &apps.settings.tools,
        &apps.store.tools,    &apps.weather.tools,    &apps.browser.tools,
    };
    for (tables) |tools| {
        try testing.expect(silentReads(tools) >= 1);
    }
}

test "the lightweight apps hold nothing consequential" {
    // Weather and Calculator prove the frame reaches even a read-mostly app without needing
    // a single held operation.
    try testing.expectEqual(@as(usize, 0), consequential(&apps.weather.tools));
    try testing.expectEqual(@as(usize, 0), consequential(&apps.calculator.tools));
}

test "the apps that send, delete, or spend always hold at least one operation" {
    // An app that can reach outside the device or move value never lets an agent do so
    // without a person — at least one of its operations is behind a hold.
    try testing.expect(consequential(&apps.messages.tools) >= 1);
    try testing.expect(consequential(&apps.files.tools) >= 1);
    try testing.expect(consequential(&apps.store.tools) >= 1);
    try testing.expect(consequential(&apps.browser.tools) >= 1);
}
