//! Contacts, agent-native: the capabilities the address book is read and maintained
//! through, over the real contacts domain, with every read confined to the granted
//! fields.
//!
//! Adding, editing, and deleting are local changes an agent may make; reading is
//! field-scoped. The capabilities are declared here for discovery, and each reaches the
//! one domain that holds the real records and enforces the field scope.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const Field = domain.Field;
pub const FieldSet = domain.FieldSet;
pub const fieldVisible = domain.fieldVisible;
pub const Kind = domain.Kind;

pub const tools = [_]framework.Tool{
    .{ .name = "contact.read", .required_capability = "contacts.read", .effect = .read_only },
    .{ .name = "contact.add", .required_capability = "contacts.write", .effect = .local_mutation },
    .{ .name = "contact.edit", .required_capability = "contacts.write", .effect = .local_mutation },
    .{ .name = "contact.delete", .required_capability = "contacts.write", .effect = .local_mutation },
    .{ .name = "contact.share", .required_capability = "contacts.share", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Contacts", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;

test "a read returns only the granted fields" {
    var granted: FieldSet = .initEmpty();
    granted.insert(.name);
    granted.insert(.email);
    try testing.expect(fieldVisible(granted, .email));
    try testing.expect(!fieldVisible(granted, .address));
}

test "maintaining the address book is the agent's own local change" {
    try testing.expect(!tools[1].effect.needsApproval());
    try testing.expect(!tools[2].effect.needsApproval());
}

test "sharing a contact outward is consequential and held for the person" {
    // The last tool is contact.share; sending a record off the device needs a person.
    const share = tools[tools.len - 1];
    try testing.expectEqualStrings("contact.share", share.name);
    try testing.expect(share.effect.needsApproval());
}
