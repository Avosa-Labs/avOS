//! The north star, end to end: two agents hold a conversation over the wire, a
//! person watches it live, and the person steps in and redirects it.
//!
//! Each of the pieces is proven in its own module; this is the whole loop working
//! together. Two agents exchange messages that travel as real IPC envelopes — encoded,
//! carried, decoded — and land as ordered turns in a shared conversation. A person's
//! transcript and live feed are attached as observers, so every turn is seen as it is
//! posted, not on a later poll. Then the person intervenes: pauses the conversation,
//! which holds further agent turns, injects a correction, and lets it resume. The
//! test asserts what the platform promises — agents talking to each other, a human
//! watching them do it in real time, and the human able to take the floor.

const std = @import("std");
const messaging = @import("../messaging/messaging.zig");
const conversation_model = @import("../conversation/conversation.zig");
const observation = @import("../observation/observation.zig");
const intervention = @import("../intervention/intervention.zig");

const testing = std.testing;

const planner: u128 = 0xB1A; // an agent that plans
const worker: u128 = 0x347; // an agent that does
const person: u128 = 0x50; // the human watching
const conversation_id: u64 = 900;
const conversation_task: u128 = 0x9A5;

/// Builds a wire-encoded agent message, decodes it back, and posts it to the
/// conversation — the full over-the-wire path an agent-to-agent message takes.
///
/// The wire bytes are allocated from an arena the caller keeps alive for the whole
/// conversation, because a posted turn borrows its content from those bytes: the
/// transcript that outlives a single call must still be able to read them, exactly
/// the ownership rule the observation module documents.
fn sendOverWire(
    conversation: *conversation_model.Conversation,
    wire: std.mem.Allocator,
    message: messaging.Message,
    provenance: conversation_model.Provenance,
) !u64 {
    const bytes = try wire.alloc(u8, message.encodedSize());
    _ = try message.encode(bytes);
    // The recipient decodes the same bytes it received — no shortcut around the wire.
    const delivered = try messaging.Message.decode(bytes);
    return conversation.post(delivered, provenance);
}

fn agentSays(id: u128, from: u128, kind: messaging.Kind, content: []const u8) messaging.Message {
    return .{ .id = id, .from = from, .conversation = conversation_id, .task = conversation_task, .kind = kind, .content = content };
}

test "two agents converse over the wire while a person watches live and steps in" {
    const gpa = testing.allocator;
    // The wire bytes must outlive the conversation, since turns borrow their content
    // from them; the arena is declared first so it is torn down last.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const wire = arena_state.allocator();

    var conversation = conversation_model.Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    // The person attaches a durable transcript and a live feed before anything is said.
    var transcript = observation.Transcript.init(gpa);
    defer transcript.deinit();
    try conversation.observe(transcript.observer());

    var feed_buffer: [1024]u8 = undefined;
    var feed = observation.Feed.init(&feed_buffer);
    try conversation.observe(feed.observer());

    // The planner asks the worker to do something; the worker reports back. Both
    // messages travel as real encoded envelopes.
    _ = try sendOverWire(&conversation, wire, agentSays(1, planner, .request, "book the 9am flight to Boston"), .agent);
    _ = try sendOverWire(&conversation, wire, agentSays(2, worker, .report, "found a 9am flight, ready to book"), .agent);

    // The person has been watching live: the feed already shows both turns.
    try testing.expect(std.mem.indexOf(u8, feed.text(), "book the 9am flight") != null);
    try testing.expect(std.mem.indexOf(u8, feed.text(), "ready to book") != null);

    // The person steps in: pause, so the worker cannot proceed to book.
    _ = try intervention.pause(&conversation, person);
    try testing.expectError(error.Paused, sendOverWire(&conversation, wire, agentSays(3, worker, .report, "booked!"), .agent));

    // The person injects a correction while paused, then resumes.
    _ = try intervention.inject(&conversation, person, agentSays(4, person, .say, "not Boston — the meeting moved to New York"));
    _ = try intervention.resumeConversation(&conversation, person);
    _ = try sendOverWire(&conversation, wire, agentSays(5, worker, .report, "understood, searching flights to New York"), .agent);

    // The transcript is the faithful, complete record of the whole exchange.
    try testing.expect(transcript.isComplete());
    const turns = transcript.recorded();
    try testing.expectEqual(@as(usize, 4), turns.len); // two agent, one human, one agent; the paused "booked!" never landed

    // The human turn is in the record, marked as the person's, in its place in order.
    try testing.expectEqual(conversation_model.Provenance.human, turns[2].provenance);
    try testing.expectEqualStrings("not Boston — the meeting moved to New York", turns[2].message.content);
    // The conversation resumed and the worker's corrected report is the last turn.
    try testing.expectEqual(messaging.Kind.report, turns[3].message.kind);
    try testing.expect(std.mem.indexOf(u8, turns[3].message.content, "New York") != null);
}

test "an agent message misrouted to the wrong conversation never lands" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var conversation = conversation_model.Conversation.init(gpa, conversation_id, conversation_task);
    defer conversation.deinit();

    var misrouted = agentSays(1, planner, .say, "for another conversation");
    misrouted.conversation = conversation_id + 1;
    try testing.expectError(error.Mismatched, sendOverWire(&conversation, arena_state.allocator(), misrouted, .agent));
    try testing.expectEqual(@as(usize, 0), conversation.length());
}
