//! Deciding whether an agent may even attempt an effect, so an agent configured for
//! one kind of work cannot try another however its plan is worded.
//!
//! Beyond the capabilities an agent holds, a person sets what an agent is *for*: a
//! research agent reads and summarises, a scheduling agent may also make local
//! changes, and only a few agents are ever meant to spend money or send on a person's
//! behalf. That intent is a policy envelope, and it is enforced before capability
//! checks, not after, because an agent that can even attempt a consequential effect is
//! an agent whose every plan has to be watched for one. Holding the envelope tight
//! means a research agent's plan that proposes a payment is refused at the door — the
//! effect class is outside what this agent may attempt — rather than proposed,
//! capability-checked, and held for approval. The envelope is the coarse gate; the
//! capability system and human approval are the fine ones behind it. Together they
//! mean an agent does only the kind of thing it was set up to do.
//!
//! This module attempts nothing. It decides whether an effect class is within an
//! agent's policy envelope, as a pure function so the coarse gate is one place.

const std = @import("std");

/// A class of effect an agent action may have, ordered by consequence.
pub const Effect = enum {
    /// Read state; change nothing.
    read,
    /// Change local, reversible state.
    local_write,
    /// Reach off the device: send, fetch, publish.
    external,
    /// Move value or grant authority.
    value_transfer,
};

/// An agent's policy envelope: the set of effect classes it may attempt at all.
pub const Envelope = std.EnumSet(Effect);

/// Whether an agent with the given envelope may attempt an effect.
///
/// Only effects inside the envelope may be attempted. Anything outside is refused
/// before any capability or approval check, so an agent never even proposes an effect
/// it was not set up to have. An empty envelope permits nothing but the safest reads
/// are still gated: the envelope is the whole of what may be attempted.
pub fn mayAttempt(envelope: Envelope, effect: Effect) bool {
    return envelope.contains(effect);
}

/// A common envelope: a read-only agent may only read.
pub fn readOnly() Envelope {
    var envelope: Envelope = .initEmpty();
    envelope.insert(.read);
    return envelope;
}

/// A common envelope: an agent that reads and makes local changes but reaches nothing
/// off the device and moves no value.
pub fn localAgent() Envelope {
    var envelope: Envelope = .initEmpty();
    envelope.insert(.read);
    envelope.insert(.local_write);
    return envelope;
}

fn envelopeOf(effects: []const Effect) Envelope {
    var envelope: Envelope = .initEmpty();
    for (effects) |effect| envelope.insert(effect);
    return envelope;
}

test "a read-only agent may read but not write, reach out, or transfer" {
    const envelope = readOnly();
    try std.testing.expect(mayAttempt(envelope, .read));
    try std.testing.expect(!mayAttempt(envelope, .local_write));
    try std.testing.expect(!mayAttempt(envelope, .external));
    try std.testing.expect(!mayAttempt(envelope, .value_transfer));
}

test "a local agent may read and write locally but not reach out or transfer" {
    const envelope = localAgent();
    try std.testing.expect(mayAttempt(envelope, .read));
    try std.testing.expect(mayAttempt(envelope, .local_write));
    try std.testing.expect(!mayAttempt(envelope, .external));
    try std.testing.expect(!mayAttempt(envelope, .value_transfer));
}

test "a value transfer is refused unless the envelope includes it" {
    const without = localAgent();
    try std.testing.expect(!mayAttempt(without, .value_transfer));
    const with = envelopeOf(&.{ .read, .external, .value_transfer });
    try std.testing.expect(mayAttempt(with, .value_transfer));
}

test "an empty envelope permits nothing" {
    const empty: Envelope = .initEmpty();
    for (std.enums.values(Effect)) |effect| {
        try std.testing.expect(!mayAttempt(empty, effect));
    }
}

test "an attempt is permitted exactly when the effect is in the envelope, swept" {
    // The envelope property: mayAttempt is true iff the effect was included.
    const envelope = envelopeOf(&.{ .read, .external });
    for (std.enums.values(Effect)) |effect| {
        try std.testing.expectEqual(envelope.contains(effect), mayAttempt(envelope, effect));
    }
}
