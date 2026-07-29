//! The Home domain: the real devices a person's home holds — lights, plugs, and locks — their state,
//! and the one consequential act over them, unlocking a lock, which reaches the physical world and so
//! is held for the person.
//!
//! This is the "one domain" both doors reach. It holds each device and whether it is on — a light lit,
//! a plug powered, a lock engaged. Listing devices and reading a device's state are silent; turning a
//! light or plug on or off, and locking a lock, are ordinary local changes an agent may make and the
//! person sees. Unlocking a lock is the single act that lowers a physical barrier, so the frame holds
//! an agent's unlock for the person and applies it exactly once by key — an agent may secure the home
//! freely, but opening it is the person's to approve. An agent adjusting the lights runs the identical
//! code the person's finger runs, over the same devices.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A kind of device. A lock's "on" means engaged (locked); a light's or plug's means powered.
pub const Kind = enum { light, plug, lock };

const Device = struct { name: []const u8, kind: Kind, on: bool };
const Applied = struct { key: u128, result: []const u8 };

/// The Home store: the real devices and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    devices: std.ArrayListUnmanaged(Device) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.devices.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.devices.items.len;
    }

    /// Registers a device in its starting state — how the home is populated. A lock starts engaged.
    pub fn addDevice(store: *Store, name: []const u8, kind: Kind, on: bool) !void {
        try store.devices.append(store.gpa, .{ .name = name, .kind = kind, .on = on });
    }

    fn find(store: *Store, name: []const u8) ?*Device {
        for (store.devices.items) |*device| {
            if (std.mem.eql(u8, device.name, name)) return device;
        }
        return null;
    }

    /// Whether a device is on (a light lit, a plug powered, a lock engaged), or null if there is no
    /// such device.
    pub fn isOn(store: *Store, name: []const u8) ?bool {
        return if (store.find(name)) |device| device.on else null;
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

    /// The one entry point both doors reach. For a set `args` is "name@on" or "name@off"; for a status
    /// or unlock it is a device name.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "home.list")) return .{ .ok = "listed" };
        if (std.mem.eql(u8, op, "home.status")) {
            const on = store.isOn(input.args) orelse return .failed;
            return .{ .ok = if (on) "on" else "off" };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "home.set")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const device = store.find(input.args[0..at]) orelse return .failed;
            const on = if (std.mem.eql(u8, input.args[at + 1 ..], "on")) true else if (std.mem.eql(u8, input.args[at + 1 ..], "off")) false else return .failed;
            // A lock is never opened through the ordinary set path — lowering a physical barrier is the
            // held act. Locking one (on) is fine; unlocking (off) must go through home.unlock.
            if (device.kind == .lock and !on) return .failed;
            device.on = on;
            return store.commit(key, "set");
        }
        // Consequential: unlocking a lock lowers a physical barrier. The frame has already held it for
        // the person; the domain applies it once and records the key.
        if (std.mem.eql(u8, op, "home.unlock")) {
            const device = store.find(input.args) orelse return .failed;
            if (device.kind != .lock) return .failed;
            device.on = false; // disengaged
            return store.commit(key, "unlocked");
        }
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

// --- Tests ---

const testing = std.testing;

fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

test "turning a light on and off is a local change, once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.addDevice("Kitchen Light", .light, false);
    _ = Store.execute(&store, .{ .operation = "home.set", .args = "Kitchen Light@on" }, agent(), 1);
    try testing.expect(store.isOn("Kitchen Light").?);
    _ = Store.execute(&store, .{ .operation = "home.set", .args = "Kitchen Light@off" }, agent(), 2);
    _ = Store.execute(&store, .{ .operation = "home.set", .args = "Kitchen Light@on" }, agent(), 2); // same key: no re-toggle
    try testing.expect(!store.isOn("Kitchen Light").?);
}

test "an agent may lock a door but not open it through the ordinary set path" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.addDevice("Front Door", .lock, true); // starts engaged
    // Locking (on) through home.set is allowed.
    _ = Store.execute(&store, .{ .operation = "home.set", .args = "Front Door@on" }, agent(), 1);
    try testing.expect(store.isOn("Front Door").?);
    // Unlocking through home.set is refused — it is the held act.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "home.set", .args = "Front Door@off" }, agent(), 2));
    try testing.expect(store.isOn("Front Door").?); // still locked
}

test "unlocking a lock is the one consequential act, applied exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.addDevice("Front Door", .lock, true);
    const first = Store.execute(&store, .{ .operation = "home.unlock", .args = "Front Door" }, agent(), 9);
    try testing.expectEqualStrings("unlocked", first.ok);
    try testing.expect(!store.isOn("Front Door").?); // disengaged
    // A re-drive under the same key returns the first result, not a second unlock.
    const again = Store.execute(&store, .{ .operation = "home.unlock", .args = "Front Door" }, agent(), 9);
    try testing.expectEqualStrings("unlocked", again.ok);
    // Unlocking a device that is not a lock fails.
    try store.addDevice("Lamp", .light, true);
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "home.unlock", .args = "Lamp" }, agent(), 10));
}
