//! The Weather domain: saved locations and their forecasts, read through a provider-neutral
//! connector, cached so an offline view shows honestly-timestamped data rather than a blank error.
//!
//! This is the "one domain" both doors reach. It holds the person's saved locations and the last
//! reading cached for each; a current or forecast read goes through a connector — an interface, so
//! which weather provider answers is an adapter choice made elsewhere, never part of the domain.
//! The simulator's deterministic connector answers in CI and offline, derived only from the place
//! name, so a run is reproducible. Reads are silent (they return external data); saving a location
//! and enabling an alert are ordinary local changes. Nothing here is consequential — Weather is the
//! deliberately light app that shows a read-mostly surface still gets the whole framework.
//!
//! This module is the app's real logic and storage; the gating and recording are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

pub const Condition = enum { clear, cloudy, rain, snow, storm };

/// A weather reading: temperature in whole degrees Celsius, and the sky.
pub const Reading = struct {
    temp_c: i16,
    condition: Condition,
};

/// The provider-neutral connector the domain reads through. A real provider adapter or the
/// simulator's deterministic connector implements it; the provider's name never enters the domain.
pub const Connector = struct {
    context: *anyopaque,
    current_fn: *const fn (context: *anyopaque, location: []const u8) Reading,

    pub fn current(connector: Connector, location: []const u8) Reading {
        return connector.current_fn(connector.context, location);
    }
};

/// A deterministic connector for CI and offline: it derives a stable reading from the place name
/// alone, so the same location always reads the same and a run is reproducible.
pub const Deterministic = struct {
    var unused: u8 = 0;

    fn current(_: *anyopaque, location: []const u8) Reading {
        var hash: u32 = 2166136261;
        for (location) |byte| hash = (hash ^ byte) *% 16777619;
        return .{
            .temp_c = @as(i16, @intCast(hash % 45)) - 10, // -10..34 C
            .condition = @enumFromInt(hash % @typeInfo(Condition).@"enum".fields.len),
        };
    }

    /// The connector handle for the deterministic provider.
    pub fn connector() Connector {
        return .{ .context = &unused, .current_fn = current };
    }
};

const Cached = struct { location: []const u8, reading: Reading, at_tick: u64 };
const Applied = struct { key: u128, result: []const u8 };

pub const Store = struct {
    gpa: std.mem.Allocator,
    connector: Connector,
    saved: std.ArrayListUnmanaged([]const u8) = .empty,
    alerts: std.ArrayListUnmanaged([]const u8) = .empty,
    cache: std.ArrayListUnmanaged(Cached) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    /// A logical clock, advanced on each read, so a cached reading's age is observable.
    tick: u64 = 0,
    reply: [24]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, connector: Connector) Store {
        return .{ .gpa = gpa, .connector = connector };
    }

    pub fn deinit(store: *Store) void {
        store.saved.deinit(store.gpa);
        store.alerts.deinit(store.gpa);
        store.cache.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn savedCount(store: Store) usize {
        return store.saved.items.len;
    }

    pub fn hasAlert(store: Store, location: []const u8) bool {
        for (store.alerts.items) |a| if (std.mem.eql(u8, a, location)) return true;
        return false;
    }

    /// The cached reading for a location and its age in ticks, or null if nothing is cached yet.
    /// This is what an offline view shows — the last reading, honestly aged.
    pub fn cached(store: Store, location: []const u8) ?struct { reading: Reading, age: u64 } {
        for (store.cache.items) |entry| {
            if (std.mem.eql(u8, entry.location, location)) {
                return .{ .reading = entry.reading, .age = store.tick - entry.at_tick };
            }
        }
        return null;
    }

    fn recordReading(store: *Store, location: []const u8, reading: Reading) void {
        for (store.cache.items) |*entry| {
            if (std.mem.eql(u8, entry.location, location)) {
                entry.reading = reading;
                entry.at_tick = store.tick;
                return;
            }
        }
        store.cache.append(store.gpa, .{ .location = location, .reading = reading, .at_tick = store.tick }) catch {};
    }

    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |e| if (e.key == key) return e.result;
        return null;
    }

    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }

    /// The one entry point both doors reach. `args` is a location name.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        // Reads: go through the connector, cache the reading, and return it. Idempotency does not
        // apply — a read may be repeated freely — but each read advances the clock so age is real.
        if (std.mem.eql(u8, op, "weather.current") or std.mem.eql(u8, op, "weather.forecast")) {
            if (input.args.len == 0) return .failed;
            store.tick += 1;
            const reading = store.connector.current(input.args);
            store.recordReading(input.args, reading);
            const text = std.fmt.bufPrint(&store.reply, "{d}C {s}", .{ reading.temp_c, @tagName(reading.condition) }) catch return .failed;
            return .{ .ok = text };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };

        if (std.mem.eql(u8, op, "weather.add_location")) {
            if (input.args.len == 0) return .failed;
            for (store.saved.items) |s| if (std.mem.eql(u8, s, input.args)) return store.commit(key, "saved");
            store.saved.append(store.gpa, input.args) catch return .failed;
            return store.commit(key, "saved");
        }
        if (std.mem.eql(u8, op, "weather.enable_alert")) {
            if (input.args.len == 0) return .failed;
            if (!store.hasAlert(input.args)) store.alerts.append(store.gpa, input.args) catch return .failed;
            return store.commit(key, "alerting");
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

fn fixture() Store {
    return Store.init(testing.allocator, Deterministic.connector());
}

test "the deterministic connector reads the same for a place every time" {
    const a = Deterministic.connector().current("Lisbon");
    const b = Deterministic.connector().current("Lisbon");
    try testing.expectEqual(a.temp_c, b.temp_c);
    try testing.expectEqual(a.condition, b.condition);
    // A different place reads differently (the hash separates them).
    const other = Deterministic.connector().current("Reykjavik");
    try testing.expect(a.temp_c != other.temp_c or a.condition != other.condition);
}

test "a current read returns a reading and caches it" {
    var store = fixture();
    defer store.deinit();
    const result = Store.execute(&store, .{ .operation = "weather.current", .args = "Lisbon" }, agent(), 0);
    switch (result) {
        .ok => |text| try testing.expect(text.len > 0),
        .failed => return error.TestUnexpectedResult,
    }
    // The reading is cached, freshly (age 0 right after the read).
    const c = store.cached("Lisbon") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0), c.age);
}

test "a cached reading ages as later reads advance the clock" {
    var store = fixture();
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "weather.current", .args = "Lisbon" }, agent(), 0);
    _ = Store.execute(&store, .{ .operation = "weather.current", .args = "Porto" }, agent(), 0);
    _ = Store.execute(&store, .{ .operation = "weather.current", .args = "Porto" }, agent(), 0);
    // Lisbon was read once, three ticks ago; its cache is stale but present, honestly aged.
    const lisbon = store.cached("Lisbon") orelse return error.TestUnexpectedResult;
    try testing.expect(lisbon.age > 0);
    try testing.expect(store.cached("Faro") == null); // never read, nothing cached
}

test "saving a location adds it once, and enabling an alert marks it" {
    var store = fixture();
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "weather.add_location", .args = "Lisbon" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "weather.add_location", .args = "Lisbon" }, agent(), 2); // same place, different key
    try testing.expectEqual(@as(usize, 1), store.savedCount());

    try testing.expect(!store.hasAlert("Lisbon"));
    _ = Store.execute(&store, .{ .operation = "weather.enable_alert", .args = "Lisbon" }, agent(), 3);
    try testing.expect(store.hasAlert("Lisbon"));
}

test "a change is exactly-once by key" {
    var store = fixture();
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "weather.add_location", .args = "Lisbon" }, agent(), 7);
    _ = Store.execute(&store, .{ .operation = "weather.add_location", .args = "Lisbon" }, agent(), 7); // same key: no second effect
    try testing.expectEqual(@as(usize, 1), store.savedCount());
}
