//! Watching a conversation as it happens and keeping the record of it afterwards, so
//! a person can follow agents working in real time and review exactly what was said.
//!
//! A conversation offers each turn to its observers as it is posted; this module is
//! what a person's view and the durable record are built from. A transcript attaches
//! as an observer and keeps every turn it is handed, so once the conversation is over
//! there is a faithful, replayable record — who said what, in order, with where each
//! turn's content came from. A live feed renders each turn into a line as it arrives,
//! the text a person actually reads while the agents are still talking. Neither
//! changes the conversation; observing is passive by construction, so watching can
//! never alter what is watched.
//!
//! The transcript records and the feed formats; steering the conversation is
//! intervention's, not an observer's.

const std = @import("std");
const conversation_model = @import("../conversation/conversation.zig");

pub const Turn = conversation_model.Turn;
pub const Provenance = conversation_model.Provenance;
pub const Observer = conversation_model.Observer;

/// A durable record of a conversation, built by observing it. Every turn the
/// conversation posts is appended, so after the fact the transcript can be replayed
/// or exported exactly as it happened.
///
/// Ownership: the transcript owns its recorded turns. Because a turn borrows its
/// message content from the conversation, a transcript is valid only while that
/// backing content lives; a transcript meant to outlive the conversation copies the
/// content, which the storage layer does when it persists one.
pub const Transcript = struct {
    gpa: std.mem.Allocator,
    turns: std.ArrayListUnmanaged(Turn) = .empty,
    /// Turns offered while the recorder was full and could not be stored. A non-zero
    /// count means the record is incomplete, which a reviewer must be told rather
    /// than shown a silently-truncated history.
    dropped: u64 = 0,
    /// A ceiling on recorded turns, so an unbounded conversation cannot grow the
    /// transcript without limit in memory before it is persisted.
    capacity: usize = 100_000,

    pub fn init(gpa: std.mem.Allocator) Transcript {
        return .{ .gpa = gpa };
    }

    pub fn deinit(transcript: *Transcript) void {
        transcript.turns.deinit(transcript.gpa);
        transcript.* = undefined;
    }

    fn record(context: *anyopaque, turn: Turn) void {
        const transcript: *Transcript = @ptrCast(@alignCast(context));
        if (transcript.turns.items.len >= transcript.capacity) {
            transcript.dropped += 1;
            return;
        }
        transcript.turns.append(transcript.gpa, turn) catch {
            transcript.dropped += 1;
        };
    }

    /// The observer to attach to a conversation so this transcript records it.
    pub fn observer(transcript: *Transcript) Observer {
        return .{ .context = transcript, .on_turn = record };
    }

    /// The recorded turns, in order.
    pub fn recorded(transcript: Transcript) []const Turn {
        return transcript.turns.items;
    }

    /// Whether the record is complete: nothing was dropped.
    pub fn isComplete(transcript: Transcript) bool {
        return transcript.dropped == 0;
    }
};

/// A short tag naming a turn's provenance, for a reader to see at a glance whether a
/// line is the person, an agent's own words, or untrusted external content.
pub fn provenanceTag(provenance: Provenance) []const u8 {
    return switch (provenance) {
        .human => "you",
        .agent => "agent",
        .external => "external",
    };
}

/// Renders one turn as a human-readable line: its provenance tag, the kind of
/// message, and the content. Deterministic, so a feed and a transcript export agree.
pub fn renderTurn(turn: Turn, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("[{d}] {s} ({s}): {s}\n", .{
        turn.sequence,
        turn.message.kind.method(),
        provenanceTag(turn.provenance),
        turn.message.content,
    });
}

/// A live feed: renders each turn into a caller-owned buffer as it arrives, the text
/// a person reads while the conversation is still going. When the buffer fills, later
/// turns are counted as overflow rather than silently lost, so the person knows the
/// feed fell behind.
pub const Feed = struct {
    buffer: []u8,
    written: usize = 0,
    /// Turns that did not fit the buffer. A non-zero count tells the reader the feed
    /// is behind and the transcript should be consulted for the full record.
    overflowed: u64 = 0,

    pub fn init(buffer: []u8) Feed {
        return .{ .buffer = buffer };
    }

    fn append(context: *anyopaque, turn: Turn) void {
        const feed: *Feed = @ptrCast(@alignCast(context));
        var writer = std.Io.Writer.fixed(feed.buffer[feed.written..]);
        renderTurn(turn, &writer) catch {
            feed.overflowed += 1;
            return;
        };
        feed.written += writer.buffered().len;
    }

    pub fn observer(feed: *Feed) Observer {
        return .{ .context = feed, .on_turn = append };
    }

    /// The text rendered so far.
    pub fn text(feed: Feed) []const u8 {
        return feed.buffer[0..feed.written];
    }
};

// --- Tests ---

const testing = std.testing;

const alice: u128 = 0xA11CE;
const conversation_id: u64 = 1;
const conversation_task: u128 = 0x9;

fn say(from: u128, content: []const u8) conversation_model.Message {
    return .{ .id = 1, .from = from, .conversation = conversation_id, .task = conversation_task, .kind = .say, .content = content };
}

test "a transcript records every turn a conversation posts" {
    const gpa = testing.allocator;
    var conversation = conversation_model.Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    var transcript = Transcript.init(gpa);
    defer transcript.deinit();
    try conversation.observe(transcript.observer());

    _ = try conversation.post(say(alice, "first"), .agent);
    _ = try conversation.post(say(alice, "second"), .external);

    try testing.expectEqual(@as(usize, 2), transcript.recorded().len);
    try testing.expect(transcript.isComplete());
    try testing.expectEqualStrings("first", transcript.recorded()[0].message.content);
    try testing.expectEqual(Provenance.external, transcript.recorded()[1].provenance);
}

test "a live feed renders turns as they arrive" {
    const gpa = testing.allocator;
    var conversation = conversation_model.Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    var buffer: [256]u8 = undefined;
    var feed = Feed.init(&buffer);
    try conversation.observe(feed.observer());

    _ = try conversation.post(say(alice, "hello"), .agent);
    try testing.expectEqualStrings("[0] agent.say (agent): hello\n", feed.text());
    _ = try conversation.post(say(alice, "again"), .agent);
    try testing.expect(std.mem.indexOf(u8, feed.text(), "again") != null);
}

test "a full transcript reports itself incomplete rather than hiding the drop" {
    const gpa = testing.allocator;
    var conversation = conversation_model.Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    var transcript = Transcript.init(gpa);
    transcript.capacity = 1;
    defer transcript.deinit();
    try conversation.observe(transcript.observer());

    _ = try conversation.post(say(alice, "kept"), .agent);
    _ = try conversation.post(say(alice, "dropped"), .agent);
    try testing.expectEqual(@as(usize, 1), transcript.recorded().len);
    try testing.expect(!transcript.isComplete());
    try testing.expectEqual(@as(u64, 1), transcript.dropped);
}

test "a feed that overflows its buffer counts the overflow" {
    const gpa = testing.allocator;
    var conversation = conversation_model.Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    var small: [16]u8 = undefined;
    var feed = Feed.init(&small);
    try conversation.observe(feed.observer());

    _ = try conversation.post(say(alice, "a short one"), .agent); // fits partially
    _ = try conversation.post(say(alice, "this line will not fit the tiny buffer"), .agent);
    try testing.expect(feed.overflowed >= 1);
}

test "provenance tags name the source for a reader" {
    try testing.expectEqualStrings("you", provenanceTag(.human));
    try testing.expectEqualStrings("agent", provenanceTag(.agent));
    try testing.expectEqualStrings("external", provenanceTag(.external));
}
