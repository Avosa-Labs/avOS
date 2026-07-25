//! The Settings domain: the real device settings a person and their agents read and
//! change — actual toggles and levels across every pane, not a placeholder.
//!
//! This is the "one domain" both doors reach, and here it holds genuine state: each
//! setting has a current value the domain stores and returns, a pane it belongs to, and
//! a sensitivity that decides whether changing it is an ordinary act or one reserved to
//! the person. An agent turning on a focus mode and a person tapping the same switch run
//! the identical code and move the same value. Reading returns the setting's real
//! current value; toggling flips a switch; setting a level moves it; and a change to a
//! protective setting — a passcode, find-my, payments — is the person's alone, refused
//! to an agent whatever it holds. Every change is exactly-once by the operation's key,
//! so an approved or re-driven change lands once.
//!
//! This module is the app's real logic and storage; the gating, recording, and approval
//! around it are the framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// The panes Settings presents, sorted by whether changing one touches the device's
/// protections. Every pane a phone needs is here.
pub const Pane = enum {
    general,
    accessibility,
    battery,
    wifi,
    bluetooth,
    display,
    sound,
    notifications,
    focus,
    privacy,
    // Protective panes: a change here requires the person, not an agent.
    security,
    lock_and_biometrics,
    find_my_device,
    payments,
    accounts,
    reset,

    pub fn isSensitive(pane: Pane) bool {
        return switch (pane) {
            .security, .lock_and_biometrics, .find_my_device, .payments, .accounts, .reset => true,
            else => false,
        };
    }
};

/// Whether a setting is a switch or a level.
pub const Kind = enum { toggle, level };

/// Every real setting the device exposes, its pane, its kind, and its default.
pub const Setting = enum {
    // general
    software_update_auto,
    // accessibility
    text_size,
    voiceover,
    reduce_motion,
    increase_contrast,
    bold_text,
    // battery
    low_power_mode,
    battery_percentage_shown,
    // wifi
    wifi_enabled,
    wifi_ask_to_join,
    // bluetooth
    bluetooth_enabled,
    // display
    brightness,
    dark_mode,
    true_tone,
    auto_lock_minutes,
    // sound
    ringer_volume,
    silent_mode,
    // notifications
    notifications_enabled,
    show_previews,
    // focus
    do_not_disturb,
    focus_work,
    // privacy
    location_services,
    analytics_sharing,
    // security (sensitive)
    passcode_enabled,
    biometric_unlock,
    // lock_and_biometrics (sensitive)
    require_passcode_immediately,
    // find_my_device (sensitive)
    find_my_enabled,
    // payments (sensitive)
    payments_enabled,

    pub fn pane(setting: Setting) Pane {
        return switch (setting) {
            .software_update_auto => .general,
            .text_size, .voiceover, .reduce_motion, .increase_contrast, .bold_text => .accessibility,
            .low_power_mode, .battery_percentage_shown => .battery,
            .wifi_enabled, .wifi_ask_to_join => .wifi,
            .bluetooth_enabled => .bluetooth,
            .brightness, .dark_mode, .true_tone, .auto_lock_minutes => .display,
            .ringer_volume, .silent_mode => .sound,
            .notifications_enabled, .show_previews => .notifications,
            .do_not_disturb, .focus_work => .focus,
            .location_services, .analytics_sharing => .privacy,
            .passcode_enabled, .biometric_unlock => .security,
            .require_passcode_immediately => .lock_and_biometrics,
            .find_my_enabled => .find_my_device,
            .payments_enabled => .payments,
        };
    }

    pub fn kind(setting: Setting) Kind {
        return switch (setting) {
            .text_size, .brightness, .auto_lock_minutes, .ringer_volume => .level,
            else => .toggle,
        };
    }

    pub fn isSensitive(setting: Setting) bool {
        return setting.pane().isSensitive();
    }

    fn default(setting: Setting) u16 {
        return switch (setting) {
            .software_update_auto, .wifi_enabled, .wifi_ask_to_join, .bluetooth_enabled, .true_tone, .notifications_enabled, .show_previews, .location_services, .passcode_enabled, .biometric_unlock, .require_passcode_immediately, .find_my_enabled => 1,
            .brightness, .ringer_volume => 70,
            .text_size => 50,
            .auto_lock_minutes => 2,
            else => 0,
        };
    }

    fn fromName(name: []const u8) ?Setting {
        inline for (@typeInfo(Setting).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return @field(Setting, field.name);
        }
        return null;
    }
};

const setting_count = @typeInfo(Setting).@"enum".fields.len;

const Applied = struct { key: u128, result: []const u8 };

/// The Settings store: the real current value of every setting, and the record of which
/// keyed changes have taken effect.
pub const Store = struct {
    gpa: std.mem.Allocator,
    values: [setting_count]u16 = undefined,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    /// Whether the person has re-authenticated for the current sensitive change. The
    /// framework holds an agent's sensitive change for approval; a person's completes,
    /// and completing it here requires this to be set.
    reauthenticated: bool = false,
    reply: [16]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        var store: Store = .{ .gpa = gpa };
        inline for (@typeInfo(Setting).@"enum".fields) |field| {
            const setting = @field(Setting, field.name);
            store.values[@intFromEnum(setting)] = setting.default();
        }
        return store;
    }

    pub fn deinit(store: *Store) void {
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    /// The current value of a setting.
    pub fn get(store: Store, setting: Setting) u16 {
        return store.values[@intFromEnum(setting)];
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

    /// The one entry point both doors reach. The argument names the setting (and, for a
    /// level, the value as "setting=NN").
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));

        // Parse the argument: a setting name, optionally "name=value" for a level.
        var name = input.args;
        var level_value: ?u16 = null;
        if (std.mem.indexOfScalar(u8, input.args, '=')) |at| {
            name = input.args[0..at];
            level_value = std.fmt.parseInt(u16, input.args[at + 1 ..], 10) catch return .failed;
        }
        const setting = Setting.fromName(name) orelse return .failed;

        if (std.mem.eql(u8, input.operation, "settings.read")) {
            // A read returns the real current value.
            const value = store.get(setting);
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{value}) catch return .failed;
            return .{ .ok = text };
        }

        // Any change is exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };

        if (std.mem.eql(u8, input.operation, "settings.toggle")) {
            // An ordinary toggle. A sensitive setting is not reachable this way.
            if (setting.isSensitive() or setting.kind() != .toggle) return .failed;
            const index = @intFromEnum(setting);
            store.values[index] = if (store.values[index] == 0) 1 else 0;
            return store.commit(key, "toggled");
        }
        if (std.mem.eql(u8, input.operation, "settings.set")) {
            if (setting.isSensitive() or setting.kind() != .level) return .failed;
            store.values[@intFromEnum(setting)] = @min(level_value orelse return .failed, 100);
            return store.commit(key, "set");
        }
        if (std.mem.eql(u8, input.operation, "settings.sensitive_change")) {
            // The person's alone, and only after re-authentication. The framework has
            // already held any agent attempt; a person's reaches here.
            if (!setting.isSensitive()) return .failed;
            if (!store.reauthenticated) return .failed;
            const index = @intFromEnum(setting);
            store.values[index] = if (store.values[index] == 0) 1 else 0;
            store.reauthenticated = false; // one change per re-authentication
            return store.commit(key, "changed");
        }
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

// --- Tests ---

const testing = std.testing;

fn actorAgent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

test "toggling a real setting flips its stored value, exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();

    try testing.expectEqual(@as(u16, 1), store.get(.wifi_enabled)); // default on
    _ = Store.execute(&store, .{ .operation = "settings.toggle", .args = "wifi_enabled" }, actorAgent(), 0x7);
    try testing.expectEqual(@as(u16, 0), store.get(.wifi_enabled)); // now off
    // Same key again: the change does not apply a second time.
    _ = Store.execute(&store, .{ .operation = "settings.toggle", .args = "wifi_enabled" }, actorAgent(), 0x7);
    try testing.expectEqual(@as(u16, 0), store.get(.wifi_enabled));
}

test "setting a level moves the real value and clamps it" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "settings.set", .args = "brightness=40" }, actorAgent(), 1);
    try testing.expectEqual(@as(u16, 40), store.get(.brightness));
    _ = Store.execute(&store, .{ .operation = "settings.set", .args = "ringer_volume=250" }, actorAgent(), 2);
    try testing.expectEqual(@as(u16, 100), store.get(.ringer_volume)); // clamped
}

test "a sensitive setting cannot be toggled the ordinary way, and needs re-auth" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // An ordinary toggle refuses a sensitive setting.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "settings.toggle", .args = "passcode_enabled" }, actorAgent(), 1));
    // A sensitive change without re-auth fails.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "settings.sensitive_change", .args = "find_my_enabled" }, actorAgent(), 2));
    // With re-auth, it applies once and consumes the re-auth.
    store.reauthenticated = true;
    _ = Store.execute(&store, .{ .operation = "settings.sensitive_change", .args = "find_my_enabled" }, actorAgent(), 3);
    try testing.expectEqual(@as(u16, 0), store.get(.find_my_enabled)); // was 1, now toggled off
    try testing.expect(!store.reauthenticated);
}

test "reading returns the real current value" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const result = Store.execute(&store, .{ .operation = "settings.read", .args = "brightness" }, actorAgent(), 0);
    try testing.expectEqualStrings("70", result.ok);
}

test "every setting has a pane and a sensitivity, swept" {
    for (std.enums.values(Setting)) |setting| {
        _ = setting.pane();
        try testing.expectEqual(setting.pane().isSensitive(), setting.isSensitive());
    }
}
