//! Messages, the agent door: the capabilities the app registers so an agent can
//! discover and invoke messaging operations, each wired to the one shared domain.
//!
//! This is the "two doors" half of the contract. The person reaches the domain through
//! the app's surface; an agent reaches the same domain through these registered
//! capabilities, which the tool registry publishes so the planner can find a
//! `message.send`-class operation the agent holds a capability for — the app does not
//! have to be known in advance, it is discovered. Each capability declares the exact
//! authority it needs and its effect, and the effect is what decides consequence:
//! searching and drafting are the agent's to do, while sending reaches another person
//! and so is held for the person by the framework. Both doors funnel through the same
//! `App.invoke`, which calls the same `Store.execute`, so there is one code path, gated
//! and recorded once.
//!
//! This module defines the app's capabilities and assembles it over the framework; the
//! logic is the domain's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;

/// The capabilities Messages exports for agents to discover and invoke. Reading and
/// drafting are the agent's own; sending is external and therefore held for the person.
pub const tools = [_]framework.Tool{
    .{ .name = "message.search", .required_capability = "messages.read", .effect = .read_only },
    .{ .name = "message.draft", .required_capability = "messages.compose", .effect = .local_mutation },
    .{ .name = "message.send", .required_capability = "messages.send", .effect = .external },
};

/// Assembles the Messages app over the shared frame: its domain, its registered
/// capabilities, and the ledger every operation is recorded to.
pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{
        .name = "Messages",
        .domain = store.domain(),
        .tools = .{ .tools = &tools },
        .ledger = ledger,
    };
}
