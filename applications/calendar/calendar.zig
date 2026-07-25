//! Calendar, agent-native: the capabilities scheduling happens through, over the real
//! calendar domain, with inviting held and a free/busy query kept to yes-or-no.
//!
//! Reading and free/busy are reads an agent does; adding and editing are local changes;
//! inviting reaches other people and is held for the person. The capabilities are
//! declared here for discovery, and each reaches the one domain that holds the real
//! events and computes availability from them.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Availability = domain.Availability;

pub const tools = [_]framework.Tool{
    .{ .name = "calendar.read", .required_capability = "calendar.read", .effect = .read_only },
    .{ .name = "calendar.freebusy", .required_capability = "calendar.freebusy", .effect = .read_only },
    .{ .name = "calendar.add", .required_capability = "calendar.write", .effect = .local_mutation },
    .{ .name = "calendar.edit", .required_capability = "calendar.write", .effect = .local_mutation },
    .{ .name = "calendar.invite", .required_capability = "calendar.invite", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Calendar", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "inviting is external and held; reading and adding are the agent's" {
    try testing.expect(tools[4].effect.needsApproval());
    try testing.expect(!tools[0].effect.needsApproval());
    try testing.expect(!tools[2].effect.needsApproval());
}
