//! A message from one agent to another, carried on the same authenticated wire form
//! every other component uses, so an agent talking to an agent is not a private
//! side-channel but a first-class, inspectable exchange.
//!
//! Agents collaborate by talking: one asks another to do part of a job, reports what
//! it found, proposes an action for a third to approve. The temptation is to let them
//! pass native structures directly, but that would make agent-to-agent traffic the
//! one kind of message the platform cannot see, authenticate, or bind to authority —
//! exactly the traffic that most needs to be seen, because it is where an injected
//! instruction would propagate from one agent to the next. So an agent message is an
//! IPC envelope like any other: it carries the sender principal, the task it belongs
//! to, and a typed kind, and it encodes to the same canonical bytes a signature can
//! cover and an observer can read. What an agent says to another agent travels the
//! same inspected path as what an agent says to a service.
//!
//! This module defines the message and its mapping to and from the envelope; it sends
//! nothing. Delivering the bytes is the IPC transport's, and recording the exchange
//! for a person to watch is the conversation's.

const std = @import("std");
const core = @import("core");
const ipc = @import("ipc");

const identity = core.identity;

pub const Envelope = ipc.envelope.Envelope;

/// A recipient that means the whole conversation rather than one agent — a message
/// every participant and observer sees.
pub const broadcast: u128 = 0;

/// What an agent message is doing, which decides how a recipient and an observer
/// treat it. Each maps to a stable wire method so the kind survives encoding.
pub const Kind = enum {
    /// Plain speech: information, a question, a reply. Carries no authority to act.
    say,
    /// A request that another agent perform something on the sender's behalf.
    request,
    /// A proposal to take a consequential action, which an approver may hold.
    propose,
    /// A report that an action was taken.
    report,

    pub fn method(kind: Kind) []const u8 {
        return switch (kind) {
            .say => "agent.say",
            .request => "agent.request",
            .propose => "agent.propose",
            .report => "agent.report",
        };
    }

    pub fn fromMethod(name: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            const kind: Kind = @enumFromInt(field.value);
            if (std.mem.eql(u8, kind.method(), name)) return kind;
        }
        return null;
    }

    /// Whether a message of this kind carries a proposal a person may need to
    /// approve before it takes effect.
    pub fn isConsequential(kind: Kind) bool {
        return kind == .propose;
    }
};

/// One message from an agent, addressed within a conversation.
pub const Message = struct {
    /// A non-zero identifier unique to this message, carried as the envelope's
    /// idempotency key so a redelivered message is recognized rather than acted on
    /// twice. The conversation assigns it; zero is never a valid message id.
    id: u128,
    /// The agent that sent it. The wire principal; authority, if any, is the
    /// sender's, never assumed from the content.
    from: u128,
    /// The agent it is addressed to, or `broadcast` for the whole conversation.
    to: u128 = broadcast,
    /// The conversation this message belongs to. Correlates every message in one
    /// exchange, so an observer can follow a single thread.
    conversation: u64,
    /// The task the conversation serves. Binds the message to the work it is part
    /// of, so a message cannot outlive or escape its task.
    task: u128,
    kind: Kind,
    /// The message body. Borrowed; the caller owns the backing bytes.
    content: []const u8,

    /// Renders the message as a canonical IPC envelope: sender, task, kind-as-method,
    /// and content-as-payload, with the recipient carried in the capability slot so
    /// the whole addressing survives a round trip through the wire form.
    pub fn toEnvelope(message: Message) Envelope {
        return .{
            .version = ipc.envelope.current_version,
            .kind = .request,
            .correlation = message.conversation,
            .idempotency_key = message.id,
            .principal = message.from,
            .task = message.task,
            .capability = message.to,
            .deadline_nanoseconds = 0,
            .method = message.kind.method(),
            .fault = null,
            .payload = message.content,
        };
    }

    /// Reconstructs a message from a decoded envelope, or null if the envelope does
    /// not name an agent-message method.
    pub fn fromEnvelope(envelope: Envelope) ?Message {
        const kind = Kind.fromMethod(envelope.method) orelse return null;
        return .{
            .id = envelope.idempotency_key,
            .from = envelope.principal,
            .to = envelope.capability,
            .conversation = envelope.correlation,
            .task = envelope.task,
            .kind = kind,
            .content = envelope.payload,
        };
    }

    /// Encodes the message to its canonical wire bytes, into a caller-owned buffer.
    pub fn encode(message: Message, buffer: []u8) (ipc.wire.Error || error{MissingIdempotencyKey})![]const u8 {
        return ipc.envelope.encode(message.toEnvelope(), buffer);
    }

    /// The size the encoded message will take, for sizing a buffer.
    pub fn encodedSize(message: Message) usize {
        return message.toEnvelope().encodedSize();
    }

    /// Decodes wire bytes into a message, refusing bytes that are not an agent
    /// message.
    pub fn decode(bytes: []const u8) (ipc.envelope.DecodeError || error{NotAnAgentMessage})!Message {
        const envelope = try ipc.envelope.decode(bytes);
        return fromEnvelope(envelope) orelse error.NotAnAgentMessage;
    }
};

// --- Tests ---

const testing = std.testing;

const alice: u128 = 0xA11CE;
const bob: u128 = 0xB0B;

test "a message round-trips through the wire form unchanged" {
    const message: Message = .{
        .id = 0xABCD,
        .from = alice,
        .to = bob,
        .conversation = 7,
        .task = 0x77,
        .kind = .request,
        .content = "please summarize the calendar",
    };

    var buffer: [512]u8 = undefined;
    const bytes = try message.encode(&buffer);
    const decoded = try Message.decode(bytes);

    try testing.expectEqual(@as(u128, 0xABCD), decoded.id);
    try testing.expectEqual(alice, decoded.from);
    try testing.expectEqual(bob, decoded.to);
    try testing.expectEqual(@as(u64, 7), decoded.conversation);
    try testing.expectEqual(@as(u128, 0x77), decoded.task);
    try testing.expectEqual(Kind.request, decoded.kind);
    try testing.expectEqualStrings("please summarize the calendar", decoded.content);
}

test "a broadcast message is addressed to the whole conversation" {
    const message: Message = .{ .id = 1, .from = alice, .conversation = 1, .task = 1, .kind = .say, .content = "hello all" };
    try testing.expectEqual(broadcast, message.to);
    const envelope = message.toEnvelope();
    try testing.expectEqual(broadcast, envelope.capability);
}

test "each kind maps to a stable method and back" {
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        const kind: Kind = @enumFromInt(field.value);
        try testing.expectEqual(kind, Kind.fromMethod(kind.method()).?);
    }
}

test "only a proposal is consequential" {
    try testing.expect(Kind.propose.isConsequential());
    try testing.expect(!Kind.say.isConsequential());
    try testing.expect(!Kind.request.isConsequential());
    try testing.expect(!Kind.report.isConsequential());
}

test "wire bytes that are not an agent message are refused" {
    // A non-agent method encodes fine but is not an agent message.
    const envelope: Envelope = .{
        .version = ipc.envelope.current_version,
        .kind = .request,
        .correlation = 1,
        .idempotency_key = 1,
        .principal = alice,
        .task = 0,
        .capability = 0,
        .deadline_nanoseconds = 0,
        .method = "calendar.read",
        .fault = null,
        .payload = "",
    };
    var buffer: [256]u8 = undefined;
    const bytes = try ipc.envelope.encode(envelope, &buffer);
    try testing.expectError(error.NotAnAgentMessage, Message.decode(bytes));
}
