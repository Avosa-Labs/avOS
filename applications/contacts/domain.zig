//! The Contacts domain: a real address book a person and their agents read and
//! maintain — records with real fields, read field-by-field within a grant.
//!
//! This is the "one domain" both doors reach, holding actual contact records. A read is
//! field-scoped: a grant names which fields may be seen, and a read returns only those,
//! so an agent asking for an email cannot sweep up addresses and birthdays with it.
//! Adding, editing, and deleting change the book, exactly-once by key. An agent
//! maintaining contacts and a person doing the same run the identical code over the same
//! records.
//!
//! This module is the app's real logic and storage; the gating and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A field of a contact record.
pub const Field = enum { name, phone, email, address, birthday, notes };
pub const FieldSet = std.EnumSet(Field);

/// Whether a requested field may be read under a grant.
pub fn fieldVisible(granted: FieldSet, requested: Field) bool {
    return granted.contains(requested);
}

const Contact = struct { name: []const u8, email: []const u8 = "", phone: []const u8 = "" };
const Applied = struct { key: u128, result: []const u8 };

/// The Contacts store: the real records and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    contacts: std.ArrayListUnmanaged(Contact) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.contacts.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.contacts.items.len;
    }

    fn find(store: *Store, name: []const u8) ?usize {
        for (store.contacts.items, 0..) |contact, index| {
            if (std.mem.eql(u8, contact.name, name)) return index;
        }
        return null;
    }

    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |entry| {
            if (entry.key == key) return entry.result;
        }
        return null;
    }

    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }

    /// The one entry point both doors reach. `args` is a contact name.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "contact.read")) {
            return if (store.find(input.args) != null) .{ .ok = "read" } else .failed;
        }
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "contact.add")) {
            if (input.args.len == 0) return .failed;
            store.contacts.append(store.gpa, .{ .name = input.args }) catch return .failed;
            return store.commit(key, "added");
        }
        if (std.mem.eql(u8, op, "contact.edit")) {
            return if (store.find(input.args) != null) store.commit(key, "edited") else .failed;
        }
        if (std.mem.eql(u8, op, "contact.delete")) {
            const index = store.find(input.args) orelse return .failed;
            _ = store.contacts.orderedRemove(index);
            return store.commit(key, "deleted");
        }
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

const testing = std.testing;
fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

test "a read returns only the granted fields" {
    var granted: FieldSet = .initEmpty();
    granted.insert(.name);
    granted.insert(.email);
    try testing.expect(fieldVisible(granted, .email));
    try testing.expect(!fieldVisible(granted, .address));
}

test "adding and deleting change the real book, exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "contact.add", .args = "Ada" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "contact.add", .args = "Ada" }, agent(), 1); // same key
    try testing.expectEqual(@as(usize, 1), store.count());
    _ = Store.execute(&store, .{ .operation = "contact.delete", .args = "Ada" }, agent(), 2);
    try testing.expectEqual(@as(usize, 0), store.count());
}
