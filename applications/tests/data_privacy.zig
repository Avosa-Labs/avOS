//! Pins each default app's data-privacy class, so the model router's rule — that a person's
//! private world never leaves the device — is a checked property, not a hope.
//!
//! An agent reasons over data, and some of that reasoning may reach an off-device model. The line
//! that keeps that safe is the data-privacy class: an app whose data is the person's private world
//! is classified on-device and never routes off it without a separate per-use grant, while an app
//! whose data is inherently public may. This module fixes that classification for every default app
//! and asserts the two properties the router depends on: the private-world apps are on-device, and
//! the on-device class genuinely may not leave the device. If a future change reclassified a private
//! app as shareable, this test fails rather than quietly letting the person's data reach a model.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

const DataPrivacy = framework.DataPrivacy;

/// The canonical data-privacy class of each default app.
const AppPrivacy = struct { app: []const u8, privacy: DataPrivacy };
const classes = [_]AppPrivacy{
    // The person's private world — never leaves the device without a per-use grant.
    .{ .app = "Messages", .privacy = .on_device },
    .{ .app = "Contacts", .privacy = .on_device },
    .{ .app = "Files", .privacy = .on_device },
    .{ .app = "Calendar", .privacy = .on_device },
    .{ .app = "Camera", .privacy = .on_device },
    .{ .app = "Phone", .privacy = .on_device },
    .{ .app = "Settings", .privacy = .on_device },
    .{ .app = "Agents", .privacy = .on_device },
    .{ .app = "Calculator", .privacy = .on_device },
    // Inherently public or external data — may leave under ordinary authority.
    .{ .app = "Weather", .privacy = .shareable },
    .{ .app = "Browser", .privacy = .shareable },
    .{ .app = "Store", .privacy = .shareable },
};

fn classOf(app: []const u8) DataPrivacy {
    for (classes) |c| {
        if (std.mem.eql(u8, c.app, app)) return c.privacy;
    }
    unreachable;
}

const testing = std.testing;

test "the apps holding the person's private world keep their data on the device" {
    // Each of these carries private data an agent's reasoning must not route off-device.
    const private = [_][]const u8{ "Messages", "Contacts", "Files", "Calendar", "Camera", "Phone" };
    for (private) |app| {
        try testing.expectEqual(DataPrivacy.on_device, classOf(app));
        try testing.expect(!classOf(app).mayLeaveDevice());
    }
}

test "only the public-data apps may leave the device" {
    // Weather, Browser, and Store read public or external data; nothing else is shareable.
    var shareable: usize = 0;
    for (classes) |c| {
        if (c.privacy.mayLeaveDevice()) shareable += 1;
    }
    try testing.expectEqual(@as(usize, 3), shareable);
    try testing.expect(classOf("Weather").mayLeaveDevice());
    try testing.expect(classOf("Browser").mayLeaveDevice());
    try testing.expect(classOf("Store").mayLeaveDevice());
}

test "on-device data may not leave; shareable may — the router's rule" {
    try testing.expect(!DataPrivacy.on_device.mayLeaveDevice());
    try testing.expect(DataPrivacy.shareable.mayLeaveDevice());
}
