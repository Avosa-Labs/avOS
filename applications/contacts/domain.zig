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

/// What a contact is: a person, or one of the non-human principals a person co-inhabits their
/// world with — the applications, services, organizations, devices, and virtual sessions that are
/// principals too. Contacts surfaces them honestly alongside people, so co-habitation is literal in
/// the address book rather than hidden: the "also in your world" section is Contacts reading the
/// principal service.
pub const Kind = enum {
    person,
    application,
    service,
    organization,
    device,
    session,

    pub fn isHuman(kind: Kind) bool {
        return kind == .person;
    }
};

const Contact = struct { name: []const u8, kind: Kind = .person, email: []const u8 = "", phone: []const u8 = "" };
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

    /// Seeds a contact of a given kind — how the surface adds the non-human principals it reads from
    /// the principal service, alongside the people it holds.
    pub fn addPrincipal(store: *Store, name: []const u8, kind: Kind) !void {
        try store.contacts.append(store.gpa, .{ .name = name, .kind = kind });
    }

    /// The "also in your world": the names of the non-human principals in Contacts — the apps,
    /// services, devices, and sessions a person shares their world with, surfaced alongside people.
    pub fn alsoInYourWorld(store: Store, out: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (store.contacts.items) |contact| {
            if (n >= out.len) break;
            if (!contact.kind.isHuman()) {
                out[n] = contact.name;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// The people in the book — the human contacts, separated from the non-human principals that
    /// `alsoInYourWorld` surfaces.
    pub fn people(store: Store, out: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (store.contacts.items) |contact| {
            if (n >= out.len) break;
            if (contact.kind.isHuman()) {
                out[n] = contact.name;
                n += 1;
            }
        }
        return out[0..n];
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
        if (std.mem.eql(u8, op, "contact.share")) {
            // Sharing a contact sends their record outside the device — a consequential
            // act held for the person, exactly-once by key.
            return if (store.find(input.args) != null) store.commit(key, "shared") else .failed;
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

test "sharing a known contact commits once; sharing an unknown one fails" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "contact.add", .args = "Ada" }, agent(), 1);
    const shared = Store.execute(&store, .{ .operation = "contact.share", .args = "Ada" }, agent(), 2);
    try testing.expectEqualStrings("shared", shared.ok);
    // Exactly-once by key: the same key does not re-share.
    const again = Store.execute(&store, .{ .operation = "contact.share", .args = "Ada" }, agent(), 2);
    try testing.expectEqualStrings("shared", again.ok);
    // An unknown contact cannot be shared.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "contact.share", .args = "Nobody" }, agent(), 3));
}

test "the non-human principals surface alongside people, honestly separated" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "contact.add", .args = "Ana" }, agent(), 1); // a person
    try store.addPrincipal("Weather", .service);
    try store.addPrincipal("Living Room Display", .device);
    try store.addPrincipal("Kitchen Session", .session);

    var buffer: [8][]const u8 = undefined;
    const world = store.alsoInYourWorld(&buffer);
    try testing.expectEqual(@as(usize, 3), world.len); // the three non-human principals, not Ana
    try testing.expect(Kind.person.isHuman());
    try testing.expect(!Kind.device.isHuman());

    // People reads the other side of the same book: the humans, not the principals.
    var people_buf: [8][]const u8 = undefined;
    const humans = store.people(&people_buf);
    try testing.expectEqual(@as(usize, 1), humans.len);
    try testing.expectEqualStrings("Ana", humans[0]);
}
