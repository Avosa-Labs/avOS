//! The Health domain: a person's private readings — steps, heart rate, weight, kept on the device —
//! and the one consequential act over them, sharing a summary, which leaves the device and so is held
//! for the person.
//!
//! This is the "one domain" both doors reach. Recording a reading and reading the log or a daily
//! average are ordinary local work over data that never leaves the device on its own; health is the
//! app whose data is the most private, so its class is on-device-only and an agent reading it is
//! reading it in place, never exfiltrating it. Sharing a summary — to a clinician, an export — is the
//! single act that reaches outside, so the frame holds an agent's share for the person and applies it
//! exactly once by key. An agent tracking a trend runs the identical code the person's finger runs,
//! over the same readings.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
// The platform slice (calendar dates) reached through the frame — an app file may not import the core
// plane directly, so the framework re-exports what a dated reading needs.
const core = framework.platform;

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A kind of health reading. The set is fixed so the log is structured, not free text.
pub const Metric = enum { steps, heart_rate, weight };

/// One reading: a metric, its whole-number value, and the day it was taken.
const Reading = struct {
    metric: Metric,
    value: u32,
    day: core.civil.Date,
};

const Applied = struct { key: u128, result: []const u8 };

/// The Health store: the private log of readings and the record of applied keyed changes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    readings: std.ArrayListUnmanaged(Reading) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [12]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.readings.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn count(store: Store) usize {
        return store.readings.items.len;
    }

    /// How many readings are logged for a metric — what a metric's history shows.
    pub fn countOf(store: Store, metric: Metric) usize {
        var n: usize = 0;
        for (store.readings.items) |reading| {
            if (reading.metric == metric) n += 1;
        }
        return n;
    }

    /// The average of a metric's readings, rounded to a whole number, or null if there are none. This
    /// is the summary the surface shows and a share sends — a derived figure, never the raw log.
    pub fn average(store: Store, metric: Metric) ?u32 {
        var sum: u64 = 0;
        var n: u64 = 0;
        for (store.readings.items) |reading| {
            if (reading.metric == metric) {
                sum += reading.value;
                n += 1;
            }
        }
        if (n == 0) return null;
        return @intCast((sum + n / 2) / n); // rounded to nearest
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

    fn parseMetric(text: []const u8) ?Metric {
        return std.meta.stringToEnum(Metric, text);
    }

    /// The one entry point both doors reach. For a record `args` is "metric@value@YYYY-MM-DD"; for a
    /// summary or share it is a metric name.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "health.log")) return .{ .ok = "logged" };
        if (std.mem.eql(u8, op, "health.summary")) {
            const metric = parseMetric(input.args) orelse return .failed;
            const avg = store.average(metric) orelse return .{ .ok = "none" };
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{avg}) catch return .failed;
            return .{ .ok = text };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "health.record")) {
            var it = std.mem.splitScalar(u8, input.args, '@');
            const metric = parseMetric(it.next() orelse return .failed) orelse return .failed;
            const value = std.fmt.parseInt(u32, it.next() orelse return .failed, 10) catch return .failed;
            const day = parseDate(it.next() orelse return .failed) orelse return .failed;
            if (it.next() != null) return .failed;
            store.readings.append(store.gpa, .{ .metric = metric, .value = value, .day = day }) catch return .failed;
            return store.commit(key, "recorded");
        }
        // Consequential: sharing a summary leaves the device. The frame has already held it for the
        // person; the domain applies it once and records the key.
        if (std.mem.eql(u8, op, "health.share")) {
            const metric = parseMetric(input.args) orelse return .failed;
            if (store.average(metric) == null) return .failed; // nothing to share
            return store.commit(key, "shared");
        }
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

/// Parses a "YYYY-MM-DD" day, validated against real month lengths. Null on any malformed field.
fn parseDate(text: []const u8) ?core.civil.Date {
    var it = std.mem.splitScalar(u8, text, '-');
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const d = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    if (m < 1 or m > 12 or d < 1 or d > core.civil.daysInMonth(y, m)) return null;
    return .{ .year = y, .month = m, .day = d };
}

// --- Tests ---

const testing = std.testing;

fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

fn record(store: *Store, args: []const u8, key: u128) void {
    _ = Store.execute(store, .{ .operation = "health.record", .args = args }, agent(), key);
}

test "recording readings builds a private log, once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    record(&store, "steps@8000@2026-07-01", 1);
    record(&store, "steps@10000@2026-07-02", 2);
    record(&store, "steps@10000@2026-07-02", 2); // same key: no second reading
    try testing.expectEqual(@as(usize, 2), store.count());
    try testing.expectEqual(@as(usize, 2), store.countOf(.steps));
    // A malformed date is refused.
    record(&store, "steps@9000@2026-13-40", 3);
    try testing.expectEqual(@as(usize, 2), store.count());
}

test "a summary is the rounded average of a metric, never the raw log" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    record(&store, "heart_rate@60@2026-07-01", 1);
    record(&store, "heart_rate@71@2026-07-02", 2);
    // (60 + 71) / 2 = 65.5, rounded to 66.
    const result = Store.execute(&store, .{ .operation = "health.summary", .args = "heart_rate" }, agent(), 0);
    try testing.expectEqualStrings("66", result.ok);
    // A metric with no readings summarises to "none", not a failure.
    try testing.expectEqualStrings("none", Store.execute(&store, .{ .operation = "health.summary", .args = "weight" }, agent(), 0).ok);
}

test "sharing a summary is the one consequential act, applied exactly once by key" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    record(&store, "weight@70@2026-07-01", 1);
    const first = Store.execute(&store, .{ .operation = "health.share", .args = "weight" }, agent(), 9);
    const again = Store.execute(&store, .{ .operation = "health.share", .args = "weight" }, agent(), 9); // same key
    try testing.expectEqualStrings("shared", first.ok);
    try testing.expectEqualStrings("shared", again.ok); // the first result, not a second share
    // Sharing a metric with nothing logged fails — there is no summary to send.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "health.share", .args = "steps" }, agent(), 10));
}
