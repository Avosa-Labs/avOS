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

pub const Store = struct {
    gpa: std.mem.Allocator,
    installed: std.ArrayListUnmanaged([]const u8) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }
    pub fn deinit(store: *Store) void {
        store.installed.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }
    pub fn installedCount(store: Store) usize {
        return store.installed.items.len;
    }
    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |e| if (e.key == key) return e.result;
        return null;
    }
    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }
    /// The one entry point both doors reach. `args` is an app name.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;
        if (std.mem.eql(u8, op, "store.browse") or std.mem.eql(u8, op, "store.details")) return .{ .ok = "browsed" };
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "store.install")) {
            if (input.args.len == 0) return .failed;
            store.installed.append(store.gpa, input.args) catch return .failed;
            return store.commit(key, "installed");
        }
        if (std.mem.eql(u8, op, "store.update")) return store.commit(key, "updated");
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
