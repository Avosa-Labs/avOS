//! The Camera domain: real shots a person captures and a person or agent reviews and
//! shares — with capture the person's own act, never an agent's.
//!
//! This is the "one domain" both doors reach. It holds the real shots. Previewing and
//! reviewing are reads; capture appends a shot and is reachable only through the human
//! door (no agent capability names it); sharing sends a shot outside the device and is
//! held for the person, exactly-once by key.
//!
//! This module is the app's real logic and storage; the gating and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// Whether a capture may proceed: only while the visible indicator is lit and the app
/// is foreground.
pub fn mayCapture(indicator_lit: bool, foreground: bool) bool {
    return indicator_lit and foreground;
}

const Applied = struct { key: u128, result: []const u8 };

pub const Store = struct {
    gpa: std.mem.Allocator,
    shots: usize = 0,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }
    pub fn deinit(store: *Store) void {
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }
    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |e| if (e.key == key) return e.result;
        return null;
    }
    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }
    /// The human door's capture, keyed so a held shutter fires once. Not an agent
    /// capability; only the person's surface calls this.
    pub fn capture(store: *Store, key: u128) DomainResult {
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        store.shots += 1;
        return store.commit(key, "captured");
    }
    /// The one entry point the framework doors reach.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;
        if (std.mem.eql(u8, op, "camera.preview")) return .{ .ok = "preview" };
        if (std.mem.eql(u8, op, "camera.review")) {
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{store.shots}) catch return .failed;
            return .{ .ok = text };
        }
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "camera.share")) {
            if (store.shots == 0) return .failed;
            return store.commit(key, "shared");
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
test "capture proceeds only while the indicator is lit and the app is foreground" {
    try testing.expect(mayCapture(true, true));
    try testing.expect(!mayCapture(false, true));
}
test "the person's capture appends a real shot, exactly-once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.capture(1);
    _ = store.capture(1);
    try testing.expectEqual(@as(usize, 1), store.shots);
}
