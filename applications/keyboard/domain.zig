//! The Keyboard domain: the person's text shortcuts and the words they have taught the keyboard —
//! the real state behind typing, all on the device.
//!
//! This is the "one domain" both doors reach. It holds the text-replacement shortcuts (a trigger
//! expanding to a phrase) and the words learned into the personal dictionary. Reading the shortcuts and
//! expanding a trigger are silent; adding a shortcut and learning a word are ordinary local changes an
//! agent may make and the person sees the next time they type. Nothing here reaches off the device, so
//! nothing is held. An agent adding a shortcut runs the identical code the person's finger runs, over
//! the same dictionary.
//!
//! This module is the app's real logic and storage; the gating and recording are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A text-replacement shortcut: a short trigger a person types, and the phrase it expands to.
const Shortcut = struct { trigger: []const u8, expansion: []const u8 };
const Applied = struct { key: u128, result: []const u8 };

/// The Keyboard store: the shortcuts, the learned words, and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    shortcuts: std.ArrayListUnmanaged(Shortcut) = .empty,
    learned: std.ArrayListUnmanaged([]const u8) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.shortcuts.deinit(store.gpa);
        store.learned.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn shortcutCount(store: Store) usize {
        return store.shortcuts.items.len;
    }

    pub fn learnedCount(store: Store) usize {
        return store.learned.items.len;
    }

    /// The phrase a trigger expands to, or null if no shortcut matches it — how typing resolves a
    /// shortcut. A trigger with no shortcut is left as the person typed it.
    pub fn expansionOf(store: Store, trigger: []const u8) ?[]const u8 {
        for (store.shortcuts.items) |shortcut| {
            if (std.mem.eql(u8, shortcut.trigger, trigger)) return shortcut.expansion;
        }
        return null;
    }

    /// Whether a word is in the personal dictionary — a learned word is not flagged as a misspelling.
    pub fn isLearned(store: Store, word: []const u8) bool {
        for (store.learned.items) |w| if (std.mem.eql(u8, w, word)) return true;
        return false;
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

    /// The one entry point both doors reach. For a shortcut `args` is "trigger=expansion"; for expanding
    /// or learning it is a trigger or a word.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "keyboard.shortcuts")) return .{ .ok = "listed" };
        if (std.mem.eql(u8, op, "keyboard.expand")) {
            return .{ .ok = if (store.expansionOf(input.args) != null) "expanded" else "asis" };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "keyboard.add_shortcut")) {
            const eq = std.mem.indexOfScalar(u8, input.args, '=') orelse return .failed;
            const trigger = input.args[0..eq];
            if (trigger.len == 0 or store.expansionOf(trigger) != null) return .failed;
            store.shortcuts.append(store.gpa, .{ .trigger = trigger, .expansion = input.args[eq + 1 ..] }) catch return .failed;
            return store.commit(key, "added");
        }
        if (std.mem.eql(u8, op, "keyboard.learn")) {
            if (input.args.len == 0) return .failed;
            if (!store.isLearned(input.args)) store.learned.append(store.gpa, input.args) catch return .failed;
            return store.commit(key, "learned");
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

test "a shortcut expands its trigger; an unknown trigger is left as typed" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "keyboard.add_shortcut", .args = "omw=on my way" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "keyboard.add_shortcut", .args = "omw=duplicate" }, agent(), 2); // same trigger refused
    try testing.expectEqual(@as(usize, 1), store.shortcutCount());
    try testing.expectEqualStrings("on my way", store.expansionOf("omw").?);
    try testing.expectEqualStrings("expanded", Store.execute(&store, .{ .operation = "keyboard.expand", .args = "omw" }, agent(), 0).ok);
    try testing.expectEqualStrings("asis", Store.execute(&store, .{ .operation = "keyboard.expand", .args = "xyz" }, agent(), 0).ok);
}

test "learning a word adds it to the dictionary once, by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try testing.expect(!store.isLearned("Aoife"));
    _ = Store.execute(&store, .{ .operation = "keyboard.learn", .args = "Aoife" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "keyboard.learn", .args = "Aoife" }, agent(), 1); // same key: no double
    try testing.expect(store.isLearned("Aoife"));
    try testing.expectEqual(@as(usize, 1), store.learnedCount());
}
