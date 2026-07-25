//! Registering an app's capabilities on install, so the planner discovers what any
//! app can do without being taught about it — the property that makes a new Store app
//! agent-usable the moment it is installed, with no change to any agent.
//!
//! An agent does not know about Messages or Calendar by name. When an app is installed,
//! its declared capabilities are registered into the one tool set the planner queries,
//! and from then on the planner discovers, say, a `message.send`-class operation it
//! holds a capability for by *asking the registry*, not by having been coded against
//! the app. That is the whole difference between an assistant wired to a fixed set of
//! apps and a platform where any app extends what agents can do: discovery is dynamic,
//! keyed on the capabilities an app declares and the ones an agent holds. This module
//! is that registration — it gathers the installed apps' tools into one registry and
//! answers what an agent may discover in it.
//!
//! This module installs nothing itself and runs no operation. It composes the installed
//! apps' declared capabilities into the registry the planner reads, as pure data.

const std = @import("std");
const framework = @import("agent_app.zig");

pub const Tool = framework.Tool;
pub const Registry = framework.Registry;

/// The registered surface of every installed app: one flat set of capabilities the
/// planner queries. An app's install adds its tools here; an uninstall would remove
/// them, so what an agent can discover tracks what is actually installed.
pub const Suite = struct {
    gpa: std.mem.Allocator,
    tools: std.ArrayListUnmanaged(Tool) = .empty,

    pub fn init(gpa: std.mem.Allocator) Suite {
        return .{ .gpa = gpa };
    }

    pub fn deinit(suite: *Suite) void {
        suite.tools.deinit(suite.gpa);
        suite.* = undefined;
    }

    /// Registers an app's capabilities on install. From now on the planner can
    /// discover them; nothing about the agent changed.
    pub fn install(suite: *Suite, app_tools: []const Tool) !void {
        try suite.tools.appendSlice(suite.gpa, app_tools);
    }

    /// The registry the planner reads — every installed app's capabilities at once.
    pub fn registry(suite: Suite) Registry {
        return .{ .tools = suite.tools.items };
    }

    /// Whether a capability of the given name is discoverable — i.e. some installed app
    /// registered it.
    pub fn discovers(suite: Suite, capability_name: []const u8) bool {
        return suite.registry().has(capability_name);
    }
};

// --- Tests ---

const testing = std.testing;

const messages_tools = [_]Tool{
    .{ .name = "message.search", .required_capability = "messages.read", .effect = .read_only },
    .{ .name = "message.send", .required_capability = "messages.send", .effect = .external },
};
const calendar_tools = [_]Tool{
    .{ .name = "calendar.add", .required_capability = "calendar.write", .effect = .local_mutation },
};

test "installing an app makes its capabilities discoverable to the planner" {
    const gpa = testing.allocator;
    var suite = Suite.init(gpa);
    defer suite.deinit();

    // Before install, nothing is discoverable.
    try testing.expect(!suite.discovers("message.send"));

    // Installing Messages registers its capabilities; the planner can now find them —
    // no agent code changed.
    try suite.install(&messages_tools);
    try testing.expect(suite.discovers("message.send"));
    try testing.expect(suite.discovers("message.search"));

    // A second app extends the discoverable surface further.
    try suite.install(&calendar_tools);
    try testing.expect(suite.discovers("calendar.add"));
}

test "the combined registry admits a held capability and denies a mismatch" {
    const gpa = testing.allocator;
    var suite = Suite.init(gpa);
    defer suite.deinit();
    try suite.install(&messages_tools);

    const reg = suite.registry();
    // An agent holding the send capability is admitted (and, being external, held).
    try testing.expect(reg.admit("message.send", "messages.send").permitsInvocation());
    // Presenting the wrong capability is denied.
    switch (reg.admit("message.send", "messages.read")) {
        .deny => {},
        else => return error.TestExpectedDenial,
    }
}

test "an operation no installed app registered is not discoverable" {
    const gpa = testing.allocator;
    var suite = Suite.init(gpa);
    defer suite.deinit();
    try suite.install(&messages_tools);
    // A capability from an app that was never installed is not found.
    try testing.expect(!suite.discovers("payment.transfer"));
}
