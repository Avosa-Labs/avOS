//! A person stepping into a conversation between agents: pausing it, injecting a
//! correction, letting it resume, or stopping it — the controls that make watching
//! agents work into supervising it.
//!
//! Observation lets a person see what agents are doing; intervention lets them act on
//! it. The two are deliberately separate: an observer can never change a conversation,
//! and every change goes through here, on a person's authority, so there is one place
//! that governs who may steer a conversation and what steering is allowed. A person
//! pauses a conversation to take the floor — halting further agent turns while leaving
//! the record intact — injects an instruction or correction into the paused
//! conversation, and either resumes it or stops it for good. The one rule the state
//! machine enforces is that a stopped conversation is final: nothing reopens it, so a
//! person who has decided to end a runaway exchange can trust that it stays ended.
//!
//! Authority to intervene is a capability like any other; this module records who
//! intervened and applies the control, and leaves deciding whether that person held
//! the authority to the capability check the caller runs first.

const std = @import("std");
const conversation_model = @import("../conversation/conversation.zig");

pub const Conversation = conversation_model.Conversation;
pub const Message = conversation_model.Message;
pub const State = conversation_model.State;

/// What a person is doing to a conversation.
pub const Directive = enum {
    /// Halt further agent turns; the record and the person's floor remain.
    pause,
    /// Resume a paused conversation so agents may post again.
    resume_,
    /// Inject the person's own turn.
    inject,
    /// End the conversation for good.
    stop,
};

pub const Error = error{
    /// The conversation is stopped and the directive cannot apply — nothing reopens a
    /// stopped conversation.
    Stopped,
    /// Resume was asked of a conversation that is not paused.
    NotPaused,
    /// The injected message does not belong to this conversation or task.
    Mismatched,
};

/// A record of one intervention: who did it and what they did. Kept so the audit of a
/// conversation shows not only what the agents said but where a person stepped in.
pub const Record = struct {
    /// The person who intervened. Their authority was checked before this was
    /// applied.
    by: u128,
    directive: Directive,
    /// The sequence the conversation was at when the intervention applied, placing it
    /// in the timeline of turns.
    at_sequence: u64,
};

/// Pauses a conversation on a person's authority, so further agent turns are held.
/// Pausing an already-paused conversation is idempotent; a stopped one cannot be
/// paused.
pub fn pause(conversation: *Conversation, by: u128) Error!Record {
    if (conversation.state == .stopped) return error.Stopped;
    const at = conversation.next_sequence;
    conversation.state = .paused;
    return .{ .by = by, .directive = .pause, .at_sequence = at };
}

/// Resumes a paused conversation. Refused unless it is actually paused, so a resume
/// cannot silently restart a stopped conversation or no-op on a running one in a way
/// that hides a mistake.
pub fn resumeConversation(conversation: *Conversation, by: u128) Error!Record {
    switch (conversation.state) {
        .paused => {},
        .running => return error.NotPaused,
        .stopped => return error.Stopped,
    }
    const at = conversation.next_sequence;
    conversation.state = .running;
    return .{ .by = by, .directive = .resume_, .at_sequence = at };
}

/// Injects a person's turn into the conversation. Admitted whether the conversation
/// is running or paused — injecting into a paused conversation is how a person
/// redirects it — and refused only once it is stopped.
pub fn inject(conversation: *Conversation, by: u128, message: Message) Error!Record {
    const at = conversation.inject(message) catch |err| return switch (err) {
        error.Stopped => error.Stopped,
        error.Mismatched => error.Mismatched,
        error.Paused => unreachable, // inject is admitted while paused
    };
    return .{ .by = by, .directive = .inject, .at_sequence = at };
}

/// Stops a conversation for good. Idempotent — stopping a stopped conversation is a
/// no-op record — because a person hitting stop twice must not be an error.
pub fn stop(conversation: *Conversation, by: u128) Record {
    const at = conversation.next_sequence;
    conversation.state = .stopped;
    return .{ .by = by, .directive = .stop, .at_sequence = at };
}

// --- Tests ---

const testing = std.testing;

const supervisor: u128 = 0x5EE;
const alice: u128 = 0xA11CE;
const conversation_id: u64 = 5;
const conversation_task: u128 = 0x50;

fn say(from: u128, content: []const u8) Message {
    return .{ .id = 1, .from = from, .conversation = conversation_id, .task = conversation_task, .kind = .say, .content = content };
}

fn freshConversation(gpa: std.mem.Allocator) Conversation {
    return Conversation.init(gpa, conversation_id, conversation_task);
}

test "pausing holds agent turns and injecting redirects, then resume continues" {
    const gpa = testing.allocator;
    var conversation = freshConversation(gpa);
    defer conversation.deinit();

    _ = try conversation.post(say(alice, "I'll email everyone the draft"), .agent);

    const paused = try pause(&conversation, supervisor);
    try testing.expectEqual(Directive.pause, paused.directive);
    try testing.expectEqual(State.paused, conversation.state);
    // Agents are held while paused.
    try testing.expectError(error.Paused, conversation.post(say(alice, "sending..."), .agent));

    // The person redirects.
    const injected = try inject(&conversation, supervisor, say(supervisor, "hold off — review it with me first"));
    try testing.expectEqual(Directive.inject, injected.directive);

    // Resume lets the agents continue.
    _ = try resumeConversation(&conversation, supervisor);
    try testing.expectEqual(State.running, conversation.state);
    _ = try conversation.post(say(alice, "understood, waiting for review"), .agent);
}

test "a stopped conversation is final" {
    const gpa = testing.allocator;
    var conversation = freshConversation(gpa);
    defer conversation.deinit();

    _ = stop(&conversation, supervisor);
    try testing.expectEqual(State.stopped, conversation.state);
    // Nothing reopens it.
    try testing.expectError(error.Stopped, pause(&conversation, supervisor));
    try testing.expectError(error.Stopped, resumeConversation(&conversation, supervisor));
    try testing.expectError(error.Stopped, inject(&conversation, supervisor, say(supervisor, "...")));
    // Stopping again is a harmless no-op record, not an error.
    const again = stop(&conversation, supervisor);
    try testing.expectEqual(Directive.stop, again.directive);
}

test "resuming a conversation that is not paused is refused" {
    const gpa = testing.allocator;
    var conversation = freshConversation(gpa);
    defer conversation.deinit();
    try testing.expectError(error.NotPaused, resumeConversation(&conversation, supervisor));
}

test "an intervention records who acted and where in the timeline" {
    const gpa = testing.allocator;
    var conversation = freshConversation(gpa);
    defer conversation.deinit();

    _ = try conversation.post(say(alice, "one"), .agent);
    _ = try conversation.post(say(alice, "two"), .agent);
    const record = try pause(&conversation, supervisor);
    try testing.expectEqual(supervisor, record.by);
    // Two turns had been posted, so the pause sits at sequence 2.
    try testing.expectEqual(@as(u64, 2), record.at_sequence);
}
