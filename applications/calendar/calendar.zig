//! Calendar, agent-native: the capabilities an agent schedules through and the
//! free/busy rule that keeps a availability query to the yes-or-no it needs to be.
//!
//! An agent finds a time, adds an event, and proposes the invitations; reading and
//! adding are the agent's to do, inviting reaches other people and is held for the
//! person. The capabilities are declared here so the planner can discover them and the
//! framework can gate each on its authority and effect. Separately, a free/busy query
//! returns only whether a slot is taken, never what fills it, because "busy" is all a
//! scheduler needs and the event's title is the calendar owner's alone.
//!
//! This module defines the app's capabilities and its free/busy rule; the shared frame
//! gates, records, and dispatches to the domain.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

/// The capabilities Calendar exports for agents to discover and invoke.
pub const tools = [_]framework.Tool{
    .{ .name = "calendar.read", .required_capability = "calendar.read", .effect = .read_only },
    .{ .name = "calendar.freebusy", .required_capability = "calendar.freebusy", .effect = .read_only },
    .{ .name = "calendar.add", .required_capability = "calendar.write", .effect = .local_mutation },
    .{ .name = "calendar.invite", .required_capability = "calendar.invite", .effect = .external },
};

const domain = @import("domain.zig");
pub const Store = domain.Store;
pub const App = framework.App;

/// Assembles the calendar app over the shared frame: its domain, its registered
/// capabilities, and the ledger every operation is recorded to. Both the human surface
/// and an agent reach the one domain through this app.
pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "calendar", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}


/// What a free/busy query is allowed to learn about a slot: only whether it is taken.
pub const Availability = enum { free, busy };

/// Answers a free/busy query for a slot, returning only its availability — never the
/// event that occupies it.
pub fn availabilityOf(slot_has_event: bool) Availability {
    return if (slot_has_event) .busy else .free;
}

// --- Tests ---

const testing = std.testing;

test "a free/busy query learns only whether a slot is taken" {
    try testing.expectEqual(Availability.busy, availabilityOf(true));
    try testing.expectEqual(Availability.free, availabilityOf(false));
}

test "inviting is external and so is held for the person, reading and adding are not" {
    try testing.expect(tools[3].effect.needsApproval()); // calendar.invite
    try testing.expect(!tools[0].effect.needsApproval()); // calendar.read
    try testing.expect(!tools[2].effect.needsApproval()); // calendar.add
}
