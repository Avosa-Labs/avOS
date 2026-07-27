//! Agents, agent-native: the flagship. The capabilities the agent roster is observed and stepped
//! into through, over the real agents domain, with the attention model deciding what surfaces.
//!
//! Observing the roster is a silent read. Intervening in an agent's work is consequential — an
//! agent asking to step into another agent's work is held for the person. The kill switch, ending
//! an agent's authority, is the person's alone: it is a domain act with no agent-reachable tool, so
//! no capability an agent holds can invoke it. This module declares the capabilities and re-exports
//! the attention model the surface ranks with; the frame gates and records, the domain holds the
//! roster.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");
const console = @import("console.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Kind = domain.Kind;
pub const Status = domain.Status;

// The attention model the surface ranks the roster and conversations with.
pub const Conversation = console.Conversation;
pub const moreProminent = console.moreProminent;
pub const mayTakeOver = console.mayTakeOver;
pub const TakeoverContext = console.TakeoverContext;

pub const tools = [_]framework.Tool{
    .{ .name = "agents.observe", .required_capability = "agents.observe", .effect = .read_only },
    .{ .name = "agents.intervene", .required_capability = "agents.intervene", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Agents", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "observing is silent; intervening is consequential and held for an agent" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        // Only intervening reaches into an agent's work; observing is a silent read.
        try testing.expectEqual(std.mem.eql(u8, tool.name, "agents.intervene"), held);
    }
}
