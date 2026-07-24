//! Deciding whether a call folds into the previous history entry, so a run of calls to one
//! number reads as a single line with a count rather than a wall of repeats.
//!
//! The call history is a person's record of who they talked to, and its readability depends on
//! grouping. When someone calls three times in a row, or a person redials the same number
//! twice while it is busy, showing three separate lines buries the rest of the history and
//! tells the person nothing they did not already know. Folding those into one entry — "Alex,
//! 3 calls" — is what keeps the log scannable. But the folding must be exact, because a wrong
//! merge hides a real event: two calls fold into one entry only when they are the same number
//! and the same direction and close together in time; a call to a different number, or in the
//! other direction, or after a gap, starts a new entry, because it is a distinct event the
//! person may need to see on its own. Merging consecutive same-number calls and splitting on
//! any difference is the whole of a history that summarizes without losing anything.
//!
//! This module records nothing. It decides whether a new call folds into the previous entry,
//! as a pure function over the two.

const std = @import("std");

/// The direction of a call.
pub const Direction = enum { incoming, outgoing, missed };

/// A call, as it would be logged.
pub const Call = struct {
    /// The other party's number, already normalized.
    number: []const u8,
    direction: Direction,
    /// When the call occurred, in milliseconds since the epoch.
    at_ms: i64,
};

/// The window, in milliseconds, within which consecutive same-number calls fold into one
/// history entry. Beyond it, a repeat is a distinct event.
pub const fold_window_ms: i64 = 60 * 60 * 1000; // one hour

/// Whether a new call folds into the previous history entry.
///
/// A call folds into the previous entry only when it is to the same number, in the same
/// direction, and within the fold window of it. A different number, a different direction, or a
/// call after the window starts a new entry, because it is a distinct event the person may need
/// to see. Folding is thus conservative: it groups only what is unmistakably a continuation.
pub fn foldsInto(previous: Call, next_call: Call) bool {
    if (!std.mem.eql(u8, previous.number, next_call.number)) return false;
    if (previous.direction != next_call.direction) return false;
    const gap = next_call.at_ms - previous.at_ms;
    return gap >= 0 and gap <= fold_window_ms;
}

fn call(number: []const u8, direction: Direction, at: i64) Call {
    return .{ .number = number, .direction = direction, .at_ms = at };
}

const t0: i64 = 1_000_000;

test "consecutive same-number same-direction calls fold" {
    const a = call("5551234", .incoming, t0);
    const b = call("5551234", .incoming, t0 + 1000);
    try std.testing.expect(foldsInto(a, b));
}

test "a call to a different number does not fold" {
    const a = call("5551234", .incoming, t0);
    const b = call("5559999", .incoming, t0 + 1000);
    try std.testing.expect(!foldsInto(a, b));
}

test "a call in the other direction does not fold" {
    const a = call("5551234", .incoming, t0);
    const b = call("5551234", .outgoing, t0 + 1000);
    try std.testing.expect(!foldsInto(a, b));
}

test "a call after the fold window starts a new entry" {
    const a = call("5551234", .incoming, t0);
    const b = call("5551234", .incoming, t0 + fold_window_ms + 1);
    try std.testing.expect(!foldsInto(a, b));
}

test "the fold window boundary is inclusive" {
    const a = call("5551234", .incoming, t0);
    const b = call("5551234", .incoming, t0 + fold_window_ms);
    try std.testing.expect(foldsInto(a, b));
}

test "a call never folds into a different number or direction, swept" {
    // The no-hidden-event property: a fold only ever happens for the same number and
    // direction within the window.
    const numbers = [_][]const u8{ "5551234", "5559999" };
    const directions = [_]Direction{ .incoming, .outgoing, .missed };
    const base = call("5551234", .incoming, t0);
    for (numbers) |num| {
        for (directions) |dir| {
            const other = call(num, dir, t0 + 1000);
            if (foldsInto(base, other)) {
                try std.testing.expectEqualStrings(base.number, other.number);
                try std.testing.expectEqual(base.direction, other.direction);
            }
        }
    }
}
