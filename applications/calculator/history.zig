//! The calculator's history: the recent expressions a person or an agent evaluated, kept so the app
//! can show what was computed and let a result be reused — a real feature of a real calculator.
//!
//! Evaluation itself is pure, but a calculator people actually use remembers: the last few
//! expressions and what they came to, most recent first, so a person can glance back or tap a prior
//! result into a new expression. This keeps that history without allocating — a small ring of fixed-
//! size entries, each holding the expression text and its outcome, overwriting the oldest once full.
//! Recording goes through evaluation, so the history is exactly what was computed, errors included: a
//! division by zero is remembered as the failed expression it was, not silently dropped.

const std = @import("std");
const domain = @import("domain.zig");

pub const capacity = 16;
const max_expression = 64;

/// One remembered evaluation: the expression as typed, and its outcome.
pub const Entry = struct {
    text: [max_expression]u8 = undefined,
    len: usize = 0,
    result: f64 = 0,
    ok: bool = false,

    pub fn expression(entry: *const Entry) []const u8 {
        return entry.text[0..entry.len];
    }
};

/// A bounded, allocation-free history of the most recent evaluations, newest first.
pub const History = struct {
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    /// How many entries are valid (saturates at capacity).
    len: usize = 0,
    /// The ring position the next entry is written to.
    head: usize = 0,

    /// Records an evaluation's expression and outcome, overwriting the oldest once full.
    fn record(history: *History, expression: []const u8, result: f64, ok: bool) void {
        var entry = Entry{ .result = result, .ok = ok };
        const n = @min(expression.len, max_expression);
        @memcpy(entry.text[0..n], expression[0..n]);
        entry.len = n;
        history.entries[history.head] = entry;
        history.head = (history.head + 1) % capacity;
        if (history.len < capacity) history.len += 1;
    }

    /// Evaluates an expression through the real calculator domain and records it — the result on
    /// success, the failed expression on error — then returns the same result or error the domain did.
    pub fn evaluateAndRecord(history: *History, expression: []const u8) domain.Error!f64 {
        if (domain.evaluate(expression)) |value| {
            history.record(expression, value, true);
            return value;
        } else |err| {
            history.record(expression, 0, false);
            return err;
        }
    }

    pub fn count(history: History) usize {
        return history.len;
    }

    /// The i-th most recent entry (0 is newest), or null if there are fewer than i+1 entries.
    pub fn recent(history: *const History, i: usize) ?Entry {
        if (i >= history.len) return null;
        // head points one past the newest; step back through the ring.
        const idx = (history.head + capacity - 1 - i) % capacity;
        return history.entries[idx];
    }
};

// --- Tests ---

const testing = std.testing;

test "an evaluation is remembered with its expression and result, newest first" {
    var history = History{};
    try testing.expectEqual(@as(f64, 14), try history.evaluateAndRecord("2+3*4"));
    try testing.expectEqual(@as(f64, 5), try history.evaluateAndRecord("1+4"));
    try testing.expectEqual(@as(usize, 2), history.count());
    const newest = history.recent(0).?;
    try testing.expectEqualStrings("1+4", newest.expression());
    try testing.expectEqual(@as(f64, 5), newest.result);
    try testing.expect(newest.ok);
    try testing.expectEqualStrings("2+3*4", history.recent(1).?.expression());
    try testing.expect(history.recent(2) == null);
}

test "a failed expression is remembered as failed, not dropped" {
    var history = History{};
    try testing.expectError(error.DivideByZero, history.evaluateAndRecord("1/0"));
    try testing.expectEqual(@as(usize, 1), history.count());
    const entry = history.recent(0).?;
    try testing.expectEqualStrings("1/0", entry.expression());
    try testing.expect(!entry.ok);
}

test "the history is bounded and overwrites the oldest once full" {
    var history = History{};
    var i: usize = 0;
    while (i < capacity + 5) : (i += 1) {
        _ = history.evaluateAndRecord("1+1") catch {};
    }
    try testing.expectEqual(@as(usize, capacity), history.count()); // saturated, never grows
    try testing.expect(history.recent(capacity - 1) != null);
    try testing.expect(history.recent(capacity) == null);
}
