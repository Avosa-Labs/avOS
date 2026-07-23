//! Reading one length-delimited message from a byte stream without trusting the
//! length a peer declares, so a stream cannot be framed into an over-large
//! allocation or a desynchronised parse.
//!
//! Messages arrive over a stream that has no message boundaries of its own — a
//! socket delivers bytes, not envelopes — so each message is prefixed with its
//! length and the reader uses that length to cut one message out of the stream.
//! The length is the first thing a peer controls and the most dangerous: a reader
//! that trusts it will try to gather however many bytes the peer claims, which a
//! hostile or broken peer sets to the maximum, turning a four-byte prefix into an
//! order to buffer gigabytes. And a reader that miscounts even once is
//! desynchronised for every message after, reading one message's body as the next
//! one's length. So framing checks the declared length against a hard ceiling
//! before it reads a single body byte, and reports precisely how many bytes it
//! consumed so the stream stays aligned.
//!
//! This module owns no socket and copies no bytes. It inspects a buffer and
//! decides whether it holds a complete message, needs more bytes, or declares a
//! length past the ceiling, returning where the message ends so the caller can
//! advance the stream exactly.

const std = @import("std");

/// The fixed width of the length prefix. A message body may be up to the ceiling;
/// four bytes is ample and its width is constant so the prefix itself never needs
/// framing.
pub const length_prefix_bytes: usize = 4;

/// The largest message body the reader will frame, matching the envelope's message
/// bound. A prefix declaring more than this is refused before any body byte is
/// read.
pub const max_message_bytes: u32 = 64 * 1024;

/// What a buffer holds when a frame is examined.
pub const Frame = union(enum) {
    /// A complete message occupying `total_bytes` from the start of the buffer:
    /// the prefix plus a `body_bytes` body. The caller advances the stream by
    /// `total_bytes`.
    complete: struct {
        /// Where the body begins, just past the prefix.
        body_offset: usize,
        /// The body's length.
        body_bytes: u32,
        /// The whole frame's length, prefix included, to advance the stream by.
        total_bytes: usize,
    },
    /// The buffer does not yet hold the whole message; `needed` more bytes are
    /// required before it can be framed. Not an error — the caller reads more and
    /// tries again.
    incomplete: struct { needed: usize },
    /// The declared body length exceeds the ceiling. The connection must be
    /// closed: the peer is broken or hostile, and there is no safe way to resync a
    /// stream whose framing cannot be trusted.
    oversized: struct { declared: u32 },
};

/// Examines a buffer and decides how it frames.
///
/// If fewer than the prefix's bytes are present, more are needed before the length
/// can even be read. Once the length is readable it is checked against the ceiling
/// first — an over-large declaration is reported as oversized without reading a
/// body byte, so the declared length can never drive an allocation. Only then is
/// the body's presence checked: if the whole body has not arrived, more bytes are
/// needed; if it has, the frame is complete and its exact extent is returned.
pub fn frame(buffer: []const u8) Frame {
    if (buffer.len < length_prefix_bytes) {
        return .{ .incomplete = .{ .needed = length_prefix_bytes - buffer.len } };
    }

    const declared = std.mem.readInt(u32, buffer[0..length_prefix_bytes], .little);
    if (declared > max_message_bytes) {
        return .{ .oversized = .{ .declared = declared } };
    }

    const total = length_prefix_bytes + declared;
    if (buffer.len < total) {
        return .{ .incomplete = .{ .needed = total - buffer.len } };
    }

    return .{ .complete = .{
        .body_offset = length_prefix_bytes,
        .body_bytes = declared,
        .total_bytes = total,
    } };
}

/// Writes a length prefix for a body of `body_bytes` into `out`, returning the
/// prefix. The counterpart to framing: a message written with this prefix reads
/// back as exactly one complete frame.
pub fn writePrefix(body_bytes: u32, out: *[length_prefix_bytes]u8) error{Oversized}![]const u8 {
    if (body_bytes > max_message_bytes) return error.Oversized;
    std.mem.writeInt(u32, out, body_bytes, .little);
    return out;
}

fn buildFrame(body: []const u8, into: []u8) []const u8 {
    var prefix: [length_prefix_bytes]u8 = undefined;
    const written = writePrefix(@intCast(body.len), &prefix) catch unreachable;
    @memcpy(into[0..written.len], written);
    @memcpy(into[written.len..][0..body.len], body);
    return into[0 .. written.len + body.len];
}

test "a complete message frames with its exact extent" {
    var storage: [128]u8 = undefined;
    const framed = buildFrame("a whole message", &storage);
    const result = frame(framed);
    switch (result) {
        .complete => |c| {
            try std.testing.expectEqual(length_prefix_bytes, c.body_offset);
            try std.testing.expectEqual(@as(u32, 15), c.body_bytes);
            try std.testing.expectEqual(framed.len, c.total_bytes);
            try std.testing.expectEqualStrings("a whole message", framed[c.body_offset..][0..c.body_bytes]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a buffer shorter than the prefix needs the rest of the prefix" {
    const two_bytes = [_]u8{ 0x10, 0x00 };
    switch (frame(&two_bytes)) {
        .incomplete => |i| try std.testing.expectEqual(length_prefix_bytes - 2, i.needed),
        else => return error.TestUnexpectedResult,
    }
}

test "a prefix present but body missing needs the rest of the body" {
    // Declares a 15-byte body but only three body bytes have arrived.
    var storage: [length_prefix_bytes + 3]u8 = undefined;
    std.mem.writeInt(u32, storage[0..length_prefix_bytes], 15, .little);
    @memset(storage[length_prefix_bytes..], 0);
    switch (frame(&storage)) {
        .incomplete => |i| try std.testing.expectEqual(@as(usize, 12), i.needed),
        else => return error.TestUnexpectedResult,
    }
}

test "an over-large declared length is oversized before any body is read" {
    var prefix: [length_prefix_bytes]u8 = undefined;
    std.mem.writeInt(u32, &prefix, max_message_bytes + 1, .little);
    switch (frame(&prefix)) {
        .oversized => |o| try std.testing.expectEqual(max_message_bytes + 1, o.declared),
        else => return error.TestUnexpectedResult,
    }
}

test "the maximum-sized body is framed, one past it is oversized" {
    var at_max: [length_prefix_bytes]u8 = undefined;
    std.mem.writeInt(u32, &at_max, max_message_bytes, .little);
    // At the ceiling it is a valid (if incomplete here) frame, not oversized.
    switch (frame(&at_max)) {
        .incomplete => {},
        else => return error.TestUnexpectedResult,
    }
}

test "an empty-body message frames as complete with a zero-length body" {
    var prefix: [length_prefix_bytes]u8 = undefined;
    std.mem.writeInt(u32, &prefix, 0, .little);
    switch (frame(&prefix)) {
        .complete => |c| {
            try std.testing.expectEqual(@as(u32, 0), c.body_bytes);
            try std.testing.expectEqual(length_prefix_bytes, c.total_bytes);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "writePrefix refuses an over-large body" {
    var out: [length_prefix_bytes]u8 = undefined;
    try std.testing.expectError(error.Oversized, writePrefix(max_message_bytes + 1, &out));
}

test "two concatenated frames are consumed one at a time without desync" {
    // The alignment property: after consuming the first frame's total_bytes, the
    // remaining buffer frames as exactly the second message.
    var storage: [128]u8 = undefined;
    const first = buildFrame("first", &storage);
    var rest: [128]u8 = undefined;
    const second = buildFrame("second message", &rest);

    var stream: [256]u8 = undefined;
    @memcpy(stream[0..first.len], first);
    @memcpy(stream[first.len..][0..second.len], second);
    const combined = stream[0 .. first.len + second.len];

    const one = frame(combined);
    const consumed = switch (one) {
        .complete => |c| blk: {
            try std.testing.expectEqualStrings("first", combined[c.body_offset..][0..c.body_bytes]);
            break :blk c.total_bytes;
        },
        else => return error.TestUnexpectedResult,
    };
    switch (frame(combined[consumed..])) {
        .complete => |c| try std.testing.expectEqualStrings(
            "second message",
            combined[consumed..][c.body_offset..][0..c.body_bytes],
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "a declared length never drives a read past the ceiling, swept" {
    // Whatever length a prefix declares, the outcome is oversized above the ceiling
    // and never oversized at or below it — the declared value alone can only
    // trigger a close, never an over-ceiling body read.
    const samples = [_]u32{ 0, 1, 100, max_message_bytes - 1, max_message_bytes, max_message_bytes + 1, std.math.maxInt(u32) };
    for (samples) |declared| {
        var prefix: [length_prefix_bytes]u8 = undefined;
        std.mem.writeInt(u32, &prefix, declared, .little);
        const result = frame(&prefix);
        if (declared > max_message_bytes) {
            try std.testing.expect(result == .oversized);
        } else {
            try std.testing.expect(result != .oversized);
        }
    }
}
