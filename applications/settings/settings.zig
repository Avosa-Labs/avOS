//! Settings, agent-native: the panes the device is adjusted through, with ordinary
//! toggles open to an agent and protective panes behind the person's re-authentication.
//!
//! An agent may flip a focus mode or adjust brightness; it may not touch what protects
//! the person. Reading is a read; an ordinary toggle is a local change; a sensitive
//! change is value-transfer and the person's alone, requiring a fresh re-authentication.
//! The capabilities are declared for discovery; the sensitivity rule sorts the panes.
//!
//! This module defines the app's capabilities, its panes, and the sensitivity rule; the
//! shared frame gates and records.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const tools = [_]framework.Tool{
    .{ .name = "settings.read", .required_capability = "settings.read", .effect = .read_only },
    .{ .name = "settings.toggle", .required_capability = "settings.write", .effect = .local_mutation },
    .{ .name = "settings.sensitive_change", .required_capability = "settings.security", .effect = .value_transfer },
};

/// The panes Settings presents, sorted by whether changing one touches the device's
/// protections.
pub const Pane = enum {
    general, accessibility, battery, wifi, bluetooth, display, sound, notifications, focus, privacy,
    security, lock_and_biometrics, find_my_device, payments, accounts, reset,

    pub fn isSensitive(pane: Pane) bool {
        return switch (pane) {
            .security, .lock_and_biometrics, .find_my_device, .payments, .accounts, .reset => true,
            else => false,
        };
    }
};

/// Whether a change to a pane may proceed given whether the person re-authenticated.
pub fn changeAllowed(pane: Pane, reauthenticated: bool) bool {
    if (pane.isSensitive()) return reauthenticated;
    return true;
}

const testing = std.testing;

test "a sensitive pane requires re-authentication, an ordinary one does not" {
    try testing.expect(changeAllowed(.wifi, false));
    try testing.expect(!changeAllowed(.security, false));
    try testing.expect(changeAllowed(.security, true));
}

test "every protective pane is marked sensitive, swept" {
    for (std.enums.values(Pane)) |pane| {
        if (pane.isSensitive()) try testing.expect(!changeAllowed(pane, false))
        else try testing.expect(changeAllowed(pane, false));
    }
}

test "a sensitive change is value-transfer and so is held" {
    try testing.expect(tools[2].effect.needsApproval());
}
