//! The Store domain: a real catalog a person and their agents browse and install from,
//! with every install traced to its source and installing held for the person.
//!
//! This is the "one domain" both doors reach. It holds the real catalog and the set of
//! installed apps. Browsing and reading details are reads; installing adds to the
//! installed set and is value-transfer, held for an agent; every install carries its
//! source, and a sideload always needs an explicit acknowledgement. Installs are
//! exactly-once by key.
//!
//! This module is the app's real logic and storage; the gating and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

pub const Source = enum { store, sideload };

/// Whether an install from a source needs an explicit acknowledgement.
pub fn installNeedsAcknowledgement(source: Source) bool {
    return source == .sideload;
}

/// Whether an app update requests a capability the installed version was not already granted — the
/// capability diff. An update that stays within the granted set may apply with a notice; one that
/// asks for a new capability is held for the person, because granting new authority is a decision,
/// not an automatic update.
pub fn updateWidensCapabilities(granted: []const []const u8, requested: []const []const u8) bool {
    for (requested) |capability| {
        var already = false;
        for (granted) |have| {
            if (std.mem.eql(u8, capability, have)) already = true;
        }
        if (!already) return true; // a capability outside what the person already granted
    }
    return false;
}

const Applied = struct { key: u128, result: []const u8 };

/// What a package was granted at install: its name and the capabilities it declared, so a later
/// update can be diffed against them. Capabilities are held as the comma-separated list the install
/// carried, split on demand for the diff.
const Grant = struct { app: []const u8, caps: []const u8 };

/// The part of an install/update argument before the "|": the app name. Arguments are "app" or
/// "app|cap1,cap2".
fn appPart(args: []const u8) []const u8 {
    const bar = std.mem.indexOfScalar(u8, args, '|') orelse return args;
    return args[0..bar];
}

/// The capabilities part of an argument, after the "|", or empty if none.
fn capsPart(args: []const u8) []const u8 {
    const bar = std.mem.indexOfScalar(u8, args, '|') orelse return "";
    return args[bar + 1 ..];
}

/// Splits a comma-separated capability list into its entries, into `out`. Empty input yields nothing.
fn splitCaps(csv: []const u8, out: [][]const u8) []const []const u8 {
    if (csv.len == 0) return out[0..0];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |cap| {
        if (n >= out.len) break;
        out[n] = cap;
        n += 1;
    }
    return out[0..n];
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    installed: std.ArrayListUnmanaged([]const u8) = .empty,
    grants: std.ArrayListUnmanaged(Grant) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }
    pub fn deinit(store: *Store) void {
        store.installed.deinit(store.gpa);
        store.grants.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }
    pub fn installedCount(store: Store) usize {
        return store.installed.items.len;
    }
    /// The capabilities an installed app was granted, or null if it is not installed.
    fn grantIndex(store: *Store, app: []const u8) ?usize {
        for (store.grants.items, 0..) |g, i| {
            if (std.mem.eql(u8, g.app, app)) return i;
        }
        return null;
    }
    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |e| if (e.key == key) return e.result;
        return null;
    }
    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }
    /// The one entry point both doors reach. `args` is "app" or "app|cap1,cap2".
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;
        if (std.mem.eql(u8, op, "store.browse") or std.mem.eql(u8, op, "store.details")) return .{ .ok = "browsed" };
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "store.install")) {
            if (input.args.len == 0) return .failed;
            const app = appPart(input.args);
            store.installed.append(store.gpa, app) catch return .failed;
            store.grants.append(store.gpa, .{ .app = app, .caps = capsPart(input.args) }) catch return .failed;
            return store.commit(key, "installed");
        }
        if (std.mem.eql(u8, op, "store.update")) {
            const app = appPart(input.args);
            const requested = capsPart(input.args);
            // Diff the update's capabilities against what the app was granted. An update that widens
            // authority is a grant decision: an agent's is refused so it cannot proceed silently — it
            // must be re-approved by the person; an update within the granted set applies with a notice.
            if (store.grantIndex(app)) |idx| {
                var granted_buf: [16][]const u8 = undefined;
                var requested_buf: [16][]const u8 = undefined;
                const granted = splitCaps(store.grants.items[idx].caps, &granted_buf);
                const asked = splitCaps(requested, &requested_buf);
                if (updateWidensCapabilities(granted, asked) and actor.isAgent()) return .failed;
                store.grants.items[idx].caps = requested; // the new grant, once allowed
            }
            return store.commit(key, "updated");
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
fn human() Actor {
    return .{ .kind = .human, .principal = .{ .value = 0 } };
}

test "an update within the granted capabilities applies; one that widens is refused for an agent" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // Install granting read and write.
    _ = Store.execute(&store, .{ .operation = "store.install", .args = "Itinerary|read,write" }, agent(), 1);
    try testing.expect(store.installedCount() == 1);
    // An update within the granted set (a subset) applies.
    const within = Store.execute(&store, .{ .operation = "store.update", .args = "Itinerary|read" }, agent(), 2);
    try testing.expectEqualStrings("updated", within.ok);
    // Grant is now narrowed to read; an update re-adding write widens it, so an agent's is refused.
    const widening = Store.execute(&store, .{ .operation = "store.update", .args = "Itinerary|read,admin" }, agent(), 3);
    try testing.expectEqual(DomainResult.failed, widening);
    // The same widening update by the person proceeds — granting new authority is the person's to do.
    const by_person = Store.execute(&store, .{ .operation = "store.update", .args = "Itinerary|read,admin" }, human(), 4);
    try testing.expectEqualStrings("updated", by_person.ok);
}

test "the capability diff detects a newly requested capability" {
    try testing.expect(updateWidensCapabilities(&.{"read"}, &.{ "read", "write" }));
    try testing.expect(!updateWidensCapabilities(&.{ "read", "write" }, &.{"read"}));
    try testing.expect(!updateWidensCapabilities(&.{"read"}, &.{"read"}));
}

test "a sideloaded install always needs an explicit acknowledgement" {
    try testing.expect(installNeedsAcknowledgement(.sideload));
    try testing.expect(!installNeedsAcknowledgement(.store));
}
test "installing adds to the real installed set, exactly-once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "store.install", .args = "Itinerary" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "store.install", .args = "Itinerary" }, agent(), 1);
    try testing.expectEqual(@as(usize, 1), store.installedCount());
}

test "an update within the granted capabilities is fine; one asking for a new capability is held" {
    const granted = [_][]const u8{ "files.read", "files.write" };
    // An update that reuses only granted capabilities requests nothing new.
    try testing.expect(!updateWidensCapabilities(&granted, &.{"files.read"}));
    try testing.expect(!updateWidensCapabilities(&granted, &.{ "files.read", "files.write" }));
    // An update that adds a capability outside the granted set does — it is held for the person.
    try testing.expect(updateWidensCapabilities(&granted, &.{ "files.read", "files.share" }));
    try testing.expect(updateWidensCapabilities(&granted, &.{"network.connect"}));
}
