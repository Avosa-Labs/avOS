//! Contacts, agent-native: the capabilities the address book is read and maintained
//! through, with every read confined to the fields that were granted.
//!
//! Adding and editing a contact are local changes an agent may make; reading is
//! field-scoped so an agent asking for an email cannot sweep up addresses and birthdays
//! with it. The capabilities are declared for discovery; the field-scope rule keeps a
//! read to what its grant names.
//!
//! This module defines the app's capabilities and its field-scope rule; the shared
//! frame gates and records.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const tools = [_]framework.Tool{
    .{ .name = "contact.read", .required_capability = "contacts.read", .effect = .read_only },
    .{ .name = "contact.add", .required_capability = "contacts.write", .effect = .local_mutation },
    .{ .name = "contact.edit", .required_capability = "contacts.write", .effect = .local_mutation },
    .{ .name = "contact.delete", .required_capability = "contacts.write", .effect = .local_mutation },
};

/// A field of a contact record.
pub const Field = enum { name, phone, email, address, birthday, notes };
pub const FieldSet = std.EnumSet(Field);

/// Whether a requested field may be read under a grant. A read returns only fields the
/// grant names.
pub fn fieldVisible(granted: FieldSet, requested: Field) bool {
    return granted.contains(requested);
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
    try testing.expect(!tools[1].effect.needsApproval()); // contact.add
    try testing.expect(!tools[2].effect.needsApproval()); // contact.edit
}
