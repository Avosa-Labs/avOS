//! The settings registry: every setting the device exposes, as a typed policy key.
//!
//! Settings are policy, not application state. Each is a stable key owned by a domain service,
//! with a typed schema, a default, and — the part that makes the platform agent-native rather
//! than cosmetic — a sensitivity class that fixes what an agent may do with it. The class is a
//! property of the setting, decided here, not of whoever asks to change it: `open` an agent may
//! change silently, `notify` applies and tells the person, `hold` waits for approval, and
//! `human_only` no capability can ever write. The Settings app and the agent door both read this
//! one registry, so a setting appears in the UI and becomes agent-reachable by being registered,
//! not by hand-wiring each surface.
//!
//! This module is the registry and its rules; the values live in the owning services, and the
//! app is a viewer over them.

const std = @import("std");

/// What an agent may do with a setting. The class is the setting's, not the caller's.
pub const Class = enum {
    /// An agent with the capability may change it silently (e.g. text size).
    open,
    /// The change applies and the person is notified (e.g. joining a known network).
    notify,
    /// The change is held for the person's approval (e.g. adding a VPN, changing DNS).
    hold,
    /// Agents may read but never write; no capability grants write (e.g. the lock method).
    human_only,

    /// Whether an agent holding the right capability may ever write this class.
    pub fn agentWritable(class: Class) bool {
        return class != .human_only;
    }

    /// Whether a write of this class needs the person before it takes effect.
    pub fn needsApproval(class: Class) bool {
        return class == .hold;
    }
};

/// The type and validity rule of a setting's value.
pub const Schema = union(enum) {
    boolean,
    /// An integer in an inclusive range.
    integer: struct { min: i64, max: i64 },
    /// One of a fixed set of string choices.
    choice: []const []const u8,
    /// Free text up to a maximum length.
    text: struct { max_len: usize },
};

/// A setting's value, matching one of the schema shapes.
pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    choice: []const u8,
    text: []const u8,
};

/// Whether `value` satisfies `schema` — the right shape and within the rule.
pub fn schemaAccepts(schema: Schema, value: Value) bool {
    return switch (schema) {
        .boolean => value == .boolean,
        .integer => |range| value == .integer and value.integer >= range.min and value.integer <= range.max,
        .choice => |choices| value == .choice and blk: {
            for (choices) |choice| {
                if (std.mem.eql(u8, choice, value.choice)) break :blk true;
            }
            break :blk false;
        },
        .text => |rule| value == .text and value.text.len <= rule.max_len,
    };
}

/// A registered setting: its stable key, the service that owns the value, its schema, its
/// default, and its sensitivity class.
pub const Key = struct {
    /// A stable dotted identifier, e.g. `display.text_size`. Never a rebrand lever.
    key: []const u8,
    /// The domain service that owns the value and answers reads and writes.
    owner: []const u8,
    schema: Schema,
    default: Value,
    class: Class,

    /// Whether a proposed value is valid for this setting.
    pub fn accepts(self: Key, value: Value) bool {
        return schemaAccepts(self.schema, value);
    }
};

/// The registry: the single source of every setting's key, schema, default, and class. A new
/// service setting appears in the app and to agents by being added here, not by UI drift.
pub const registry = [_]Key{
    // Display & appearance
    .{ .key = "display.brightness", .owner = "display", .schema = .{ .integer = .{ .min = 0, .max = 100 } }, .default = .{ .integer = 70 }, .class = .open },
    .{ .key = "display.appearance", .owner = "display", .schema = .{ .choice = &.{ "light", "dark", "auto" } }, .default = .{ .choice = "auto" }, .class = .open },
    .{ .key = "display.text_size", .owner = "display", .schema = .{ .integer = .{ .min = 80, .max = 140 } }, .default = .{ .integer = 100 }, .class = .open },
    // Sound
    .{ .key = "sound.volume", .owner = "sound", .schema = .{ .integer = .{ .min = 0, .max = 100 } }, .default = .{ .integer = 50 }, .class = .open },
    // Notifications & focus
    .{ .key = "notifications.do_not_disturb", .owner = "notifications", .schema = .boolean, .default = .{ .boolean = false }, .class = .notify },
    // Connectivity
    .{ .key = "connectivity.wifi_enabled", .owner = "connectivity", .schema = .boolean, .default = .{ .boolean = true }, .class = .notify },
    .{ .key = "connectivity.vpn_enabled", .owner = "connectivity", .schema = .boolean, .default = .{ .boolean = false }, .class = .hold },
    .{ .key = "connectivity.dns", .owner = "connectivity", .schema = .{ .text = .{ .max_len = 253 } }, .default = .{ .text = "" }, .class = .hold },
    // Privacy
    .{ .key = "privacy.clipboard_access", .owner = "privacy", .schema = .{ .choice = &.{ "ask", "allow", "deny" } }, .default = .{ .choice = "ask" }, .class = .hold },
    // Agents (the flagship panel)
    .{ .key = "agents.speculative_work", .owner = "agents", .schema = .boolean, .default = .{ .boolean = true }, .class = .notify },
    .{ .key = "agents.autonomy_external_sends", .owner = "agents", .schema = .{ .choice = &.{ "open", "notify", "hold" } }, .default = .{ .choice = "hold" }, .class = .human_only },
    // Accessibility (safety-relevant → human_only, and it drives the render pipeline)
    .{ .key = "accessibility.reduced_motion", .owner = "accessibility", .schema = .boolean, .default = .{ .boolean = false }, .class = .human_only },
    // Language & region
    .{ .key = "language.locale", .owner = "language", .schema = .{ .text = .{ .max_len = 35 } }, .default = .{ .text = "en-US" }, .class = .open },
    // Identity & security (the person's alone)
    .{ .key = "security.lock_method", .owner = "security", .schema = .{ .choice = &.{ "pin", "password", "biometric" } }, .default = .{ .choice = "pin" }, .class = .human_only },
    .{ .key = "security.developer_mode", .owner = "security", .schema = .boolean, .default = .{ .boolean = false }, .class = .human_only },
    // System
    .{ .key = "system.update_channel", .owner = "system", .schema = .{ .choice = &.{ "stable", "beta" } }, .default = .{ .choice = "stable" }, .class = .hold },
};

/// The registered setting for a key, or null if the key is not registered.
pub fn find(key: []const u8) ?Key {
    for (registry) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry;
    }
    return null;
}

// --- Tests ---

const testing = std.testing;

test "accepts enforces each schema's shape and rule" {
    try testing.expect(schemaAccepts(.boolean, .{ .boolean = true }));
    try testing.expect(!schemaAccepts(.boolean, .{ .integer = 1 })); // wrong shape

    const range = Schema{ .integer = .{ .min = 0, .max = 100 } };
    try testing.expect(schemaAccepts(range, .{ .integer = 50 }));
    try testing.expect(!schemaAccepts(range, .{ .integer = 101 })); // out of range

    const choice = Schema{ .choice = &.{ "a", "b" } };
    try testing.expect(schemaAccepts(choice, .{ .choice = "b" }));
    try testing.expect(!schemaAccepts(choice, .{ .choice = "c" })); // not a choice

    const text = Schema{ .text = .{ .max_len = 3 } };
    try testing.expect(schemaAccepts(text, .{ .text = "abc" }));
    try testing.expect(!schemaAccepts(text, .{ .text = "abcd" })); // too long
}

test "the registry sweep: every key is complete, unique, dotted, and its default is valid" {
    try testing.expect(registry.len > 0);
    for (registry, 0..) |entry, i| {
        try testing.expect(entry.key.len > 0); // has a key
        try testing.expect(entry.owner.len > 0); // has an owner service
        try testing.expect(std.mem.indexOfScalar(u8, entry.key, '.') != null); // dotted, namespaced
        try testing.expect(schemaAccepts(entry.schema, entry.default)); // default satisfies the schema

        // Keys are unique.
        for (registry[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.key, other.key));
        }
    }
}

test "every sensitivity class is exercised by the registry" {
    var seen = std.EnumSet(Class).initEmpty();
    for (registry) |entry| seen.insert(entry.class);
    inline for (.{ Class.open, Class.notify, Class.hold, Class.human_only }) |class| {
        try testing.expect(seen.contains(class));
    }
}

test "find resolves a registered key and rejects an unknown one" {
    const lock = find("security.lock_method") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Class.human_only, lock.class); // the person's alone
    try testing.expect(!lock.class.agentWritable());
    try testing.expect(find("nonexistent.key") == null);
}
