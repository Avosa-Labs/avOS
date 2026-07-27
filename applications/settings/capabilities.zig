//! The Settings agent door: the typed operations an agent reaches settings through, each governed
//! by the setting's own sensitivity class from the registry — never by the caller's capabilities.
//!
//! Reading is always allowed, so an agent can see what it would be permitted to change and plan
//! around it: the value and the class are both readable. A write is proposed, and the outcome is
//! decided by the key's class in the registry, not by anything the caller holds — open applies,
//! notify applies with a notice, hold waits for the person, and human_only is refused outright. A
//! person's write always applies. The door is thin because the policy store already carries the
//! rule; the door only names the operations and routes them through it. It reaches the registry
//! through the framework, so the app never touches the system directly.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const settings = framework.settings;

pub const Value = settings.Value;
pub const Class = settings.Class;
pub const Outcome = settings.Outcome;
pub const Store = settings.Store;
pub const Actor = settings.Actor;

/// One setting read back: its key and current value.
pub const Reading = struct {
    key: []const u8,
    value: Value,
};

/// `settings.read` — the current value of `key`, or null if it is not registered. Silent.
pub fn read(store: *const Store, key: []const u8) ?Value {
    return store.get(key);
}

/// `settings.read_group` — every setting whose key begins with `prefix` (e.g. "connectivity."),
/// written into `out`. Silent, so an agent can survey a group before proposing a change.
pub fn readGroup(store: *const Store, prefix: []const u8, out: []Reading) []const Reading {
    var count: usize = 0;
    for (settings.registry) |entry| {
        if (count >= out.len) break;
        if (std.mem.startsWith(u8, entry.key, prefix)) {
            out[count] = .{ .key = entry.key, .value = store.get(entry.key).? };
            count += 1;
        }
    }
    return out[0..count];
}

/// The approval class of writing `key`, read from the registry — so an agent can tell, before it
/// asks, whether a write would apply, notify, hold, or be refused. Null for an unknown key.
pub fn writeClass(key: []const u8) ?Class {
    const entry = settings.find(key) orelse return null;
    return entry.class;
}

/// `settings.write` — propose writing `value` to `key`. The outcome is the key's class decided
/// against `actor`, never a capability the caller presents; the value takes effect only when the
/// outcome applies. An unknown key or an invalid value is rejected.
pub fn write(store: *Store, key: []const u8, value: Value, actor: Actor) Outcome {
    return store.propose(key, value, actor);
}

// --- Tests ---

const testing = std.testing;

test "read returns the current value; an unknown key reads null" {
    var store = Store.init();
    try testing.expectEqual(@as(i64, 70), read(&store, "display.brightness").?.integer);
    try testing.expect(read(&store, "nonexistent.key") == null);
}

test "the write class is the registry's, readable before a write is attempted" {
    try testing.expectEqual(Class.open, writeClass("display.brightness").?);
    try testing.expectEqual(Class.hold, writeClass("connectivity.vpn_enabled").?);
    try testing.expectEqual(Class.human_only, writeClass("security.lock_method").?);
    try testing.expect(writeClass("nonexistent.key") == null);
}

test "a write is decided by the key's class, not the caller" {
    var store = Store.init();
    // open: an agent's write applies.
    try testing.expectEqual(Outcome.applied, write(&store, "display.brightness", .{ .integer = 40 }, .agent));
    try testing.expectEqual(@as(i64, 40), read(&store, "display.brightness").?.integer);
    // hold: an agent's write waits and does not take effect.
    try testing.expectEqual(Outcome.held_for_approval, write(&store, "connectivity.vpn_enabled", .{ .boolean = true }, .agent));
    try testing.expect(!read(&store, "connectivity.vpn_enabled").?.boolean);
    // human_only: an agent's write is refused outright, whatever it holds.
    try testing.expectEqual(Outcome.rejected_unauthorized, write(&store, "security.lock_method", .{ .choice = "password" }, .agent));
    // the person may make the same change the agent could not.
    try testing.expectEqual(Outcome.applied, write(&store, "security.lock_method", .{ .choice = "password" }, .human));
}

test "read_group surveys every key under a prefix" {
    var store = Store.init();
    var out: [8]Reading = undefined;
    const group = readGroup(&store, "connectivity.", &out);
    try testing.expect(group.len >= 3); // wifi, vpn, dns at least
    for (group) |reading| {
        try testing.expect(std.mem.startsWith(u8, reading.key, "connectivity."));
    }
}
