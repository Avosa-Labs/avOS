//! Settings, agent-native: the capabilities the device is adjusted through, over the
//! real settings domain, with ordinary toggles open to an agent and protective panes
//! behind the person's re-authentication.
//!
//! An agent may flip a focus mode, dim the screen, or join a known network — reversible
//! changes on ordinary panes. It may not touch what protects the person: a change to a
//! passcode, find-my, or payments is value-transfer and the person's alone. Reading is a
//! read; a toggle and a level set are local changes; a sensitive change is held. The
//! capabilities are declared here for the planner to discover, and each reaches the one
//! settings domain that holds the real values.
//!
//! This module defines the app's capabilities and its sensitivity rule; the shared frame
//! gates and records, and the domain holds the state.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Pane = domain.Pane;
pub const Setting = domain.Setting;

/// The capabilities Settings exports for agents to discover and invoke.
pub const tools = [_]framework.Tool{
    .{ .name = "settings.read", .required_capability = "settings.read", .effect = .read_only },
    .{ .name = "settings.toggle", .required_capability = "settings.write", .effect = .local_mutation },
    .{ .name = "settings.set", .required_capability = "settings.write", .effect = .local_mutation },
    .{ .name = "settings.sensitive_change", .required_capability = "settings.security", .effect = .value_transfer },
};

/// Assembles the Settings app over the shared frame: its domain, its registered
/// capabilities, and the ledger every operation is recorded to.
pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Settings", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

/// Whether a change to a pane may proceed given whether the person re-authenticated. A
/// sensitive pane requires a fresh authentication; an ordinary one does not.
pub fn changeAllowed(pane: Pane, reauthenticated: bool) bool {
    if (pane.isSensitive()) return reauthenticated;
    return true;
}

// --- Tests ---

const testing = std.testing;

test "a sensitive pane requires re-authentication, an ordinary one does not" {
    try testing.expect(changeAllowed(.wifi, false));
    try testing.expect(!changeAllowed(.security, false));
    try testing.expect(changeAllowed(.security, true));
}

test "every protective pane is marked sensitive, swept" {
    for (std.enums.values(Pane)) |pane| {
        if (pane.isSensitive()) try testing.expect(!changeAllowed(pane, false)) else try testing.expect(changeAllowed(pane, false));
    }
}

test "a sensitive change is value-transfer and so is held" {
    try testing.expect(tools[3].effect.needsApproval());
}
