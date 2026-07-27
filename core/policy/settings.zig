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

/// The index of a key in the registry, or null.
fn indexOf(key: []const u8) ?usize {
    for (registry, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.key, key)) return i;
    }
    return null;
}

/// Who is attempting a write. The person may change anything; an agent is bound by the class.
pub const Actor = enum { human, agent };

/// What a proposed write resolves to. The class decides it — never the caller's capabilities.
pub const Outcome = enum {
    /// Applied immediately, no notice (an `open` setting).
    applied,
    /// Applied, and the person is notified (a `notify` setting changed by an agent).
    applied_with_notice,
    /// Not applied yet — held for the person's approval (a `hold` setting changed by an agent).
    held_for_approval,
    /// Refused: an agent may never write this setting (a `human_only` setting).
    rejected_unauthorized,
    /// Refused: the value does not satisfy the setting's schema.
    rejected_invalid,

    /// Whether the value takes effect now (as opposed to being held or refused).
    pub fn applies(outcome: Outcome) bool {
        return outcome == .applied or outcome == .applied_with_notice;
    }
};

/// Resolves a write of `class` by `actor` — purely from the class, not from any capability the
/// caller holds. The person may change anything; an agent is bound: open applies, notify applies
/// with notice, hold waits for approval, and human_only is refused outright.
pub fn decide(class: Class, actor: Actor) Outcome {
    if (actor == .human) return .applied;
    return switch (class) {
        .open => .applied,
        .notify => .applied_with_notice,
        .hold => .held_for_approval,
        .human_only => .rejected_unauthorized,
    };
}

/// The current value of every setting. Settings-the-app owns none of this; the values live with
/// their owning services, and this is the shape a service holds for its keys. A write is resolved
/// by the setting's class before it can take effect, so the enforcement is here, not in any UI.
pub const Store = struct {
    values: [registry.len]Value,

    /// A store with every setting at its registered default.
    pub fn init() Store {
        var store: Store = .{ .values = undefined };
        for (registry, 0..) |entry, i| store.values[i] = entry.default;
        return store;
    }

    /// The current value of `key`, or null if the key is not registered.
    pub fn get(store: Store, key: []const u8) ?Value {
        const i = indexOf(key) orelse return null;
        return store.values[i];
    }

    /// Proposes writing `value` to `key` as `actor`. The value is validated against the schema,
    /// then the class decides the outcome; the value takes effect only when the outcome applies.
    /// An unknown key is rejected as invalid.
    pub fn propose(store: *Store, key: []const u8, value: Value, actor: Actor) Outcome {
        const i = indexOf(key) orelse return .rejected_invalid;
        const entry = registry[i];
        if (!schemaAccepts(entry.schema, value)) return .rejected_invalid;
        const outcome = decide(entry.class, actor);
        if (outcome.applies()) store.values[i] = value;
        return outcome;
    }
};

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

test "the class decides a write, not the caller — an agent is bound, the person is not" {
    // Each class, as an agent sees it.
    try testing.expectEqual(Outcome.applied, decide(.open, .agent));
    try testing.expectEqual(Outcome.applied_with_notice, decide(.notify, .agent));
    try testing.expectEqual(Outcome.held_for_approval, decide(.hold, .agent));
    try testing.expectEqual(Outcome.rejected_unauthorized, decide(.human_only, .agent));
    // The person may change anything, including a human_only setting.
    for ([_]Class{ .open, .notify, .hold, .human_only }) |class| {
        try testing.expectEqual(Outcome.applied, decide(class, .human));
    }
}

test "an agent's write to a human_only setting is refused and changes nothing" {
    var store = Store.init();
    const before = store.get("security.lock_method").?;
    // Even a valid value is refused for an agent, whatever capabilities it might hold.
    const outcome = store.propose("security.lock_method", .{ .choice = "biometric" }, .agent);
    try testing.expectEqual(Outcome.rejected_unauthorized, outcome);
    try testing.expectEqualStrings(before.choice, store.get("security.lock_method").?.choice); // unchanged
    // The person can make the same change.
    try testing.expectEqual(Outcome.applied, store.propose("security.lock_method", .{ .choice = "biometric" }, .human));
    try testing.expectEqualStrings("biometric", store.get("security.lock_method").?.choice);
}

test "an open setting applies for an agent; a hold setting is held, not applied" {
    var store = Store.init();
    try testing.expectEqual(Outcome.applied, store.propose("display.text_size", .{ .integer = 120 }, .agent));
    try testing.expectEqual(@as(i64, 120), store.get("display.text_size").?.integer);

    // A hold setting: the outcome is "held" and the value has not taken effect yet.
    const dns_before = store.get("connectivity.dns").?.text;
    try testing.expectEqual(Outcome.held_for_approval, store.propose("connectivity.dns", .{ .text = "1.1.1.1" }, .agent));
    try testing.expectEqualStrings(dns_before, store.get("connectivity.dns").?.text); // not applied until approved
}

test "a value that violates the schema is rejected before the class is consulted" {
    var store = Store.init();
    try testing.expectEqual(Outcome.rejected_invalid, store.propose("display.text_size", .{ .integer = 9999 }, .agent)); // out of range
    try testing.expectEqual(Outcome.rejected_invalid, store.propose("display.text_size", .{ .boolean = true }, .agent)); // wrong shape
    try testing.expectEqual(Outcome.rejected_invalid, store.propose("nonexistent.key", .{ .boolean = true }, .human)); // unknown key
    try testing.expectEqual(@as(i64, 100), store.get("display.text_size").?.integer); // still the default
}
