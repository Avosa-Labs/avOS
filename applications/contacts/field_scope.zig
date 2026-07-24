//! Deciding which fields of a contact an app may read, so granting an app "your contacts" hands it
//! the names and numbers it needs and not the private notes attached to a person.
//!
//! A contact card holds more than a name and a number: it can carry a home address, a birthday, a
//! relationship, and free-form notes a person wrote for themselves — "spare key under the mat",
//! "going through a divorce". An app that legitimately needs to look up a phone number has no
//! business reading any of that. So contact access is scoped by field class, not all-or-nothing: an
//! app granted basic access reads the identifying fields — name, the numbers and addresses used to
//! reach someone — and never the private fields unless the person separately granted them. The
//! private class is withheld by default because it is the class whose leak actually hurts, and a
//! blanket "allow contacts" prompt is not informed consent to it. Scoping reads to the granted class
//! keeps a contact lookup a lookup rather than a dossier hand-off.
//!
//! This module reads no contact. It decides whether an app may read a given contact field, from the
//! field's class and the app's granted scope, as a pure function.

const std = @import("std");

/// How private a contact field is.
pub const Field = enum {
    /// Identifying and reachability fields: name, phone, email, postal address. Basic access reads these.
    identifying,
    /// Private fields: notes, relationship, significant dates. Read only under an explicit grant.
    private,
};

/// What the person granted an app over their contacts.
pub const Scope = enum {
    /// No contact access. Nothing is readable.
    none,
    /// Basic access: the identifying fields only.
    basic,
    /// Full access: identifying and private fields, granted explicitly.
    full,
};

/// Whether an app with a given scope may read a contact field.
///
/// No scope reads nothing. Basic scope reads identifying fields but never private ones. Full scope
/// reads both, and is reached only by an explicit grant, so the private notes on a card are never
/// disclosed by a generic "allow contacts" the person tapped without knowing it covered them.
pub fn mayRead(scope: Scope, field: Field) bool {
    return switch (scope) {
        .none => false,
        .basic => field == .identifying,
        .full => true,
    };
}

test "no scope reads nothing" {
    try std.testing.expect(!mayRead(.none, .identifying));
    try std.testing.expect(!mayRead(.none, .private));
}

test "basic scope reads identifying fields but not private ones" {
    try std.testing.expect(mayRead(.basic, .identifying));
    try std.testing.expect(!mayRead(.basic, .private));
}

test "full scope reads both classes" {
    try std.testing.expect(mayRead(.full, .identifying));
    try std.testing.expect(mayRead(.full, .private));
}

test "private fields need full scope, swept" {
    // The private-by-grant property: a private field is readable only under full scope.
    for ([_]Scope{ .none, .basic, .full }) |scope| {
        if (mayRead(scope, .private)) {
            try std.testing.expectEqual(Scope.full, scope);
        }
    }
}
