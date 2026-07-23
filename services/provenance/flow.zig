//! Deciding whether data may flow from where it came to where it is going, so
//! untrusted input cannot reach a sensitive sink without being endorsed first.
//!
//! On an agent-native device the most dangerous data is the data that came from
//! outside — a web page, a document, the output of a model that read one. It is fine
//! to display it, summarise it, reason about it; it is not fine to let it silently
//! become an instruction that moves money or changes settings, because that is how a
//! prompt injection turns a page a person opened into an action they never asked for.
//! Provenance is the taint that travels with data: input from outside is untrusted,
//! and a sink that has real effect — sending, paying, granting authority — is
//! sensitive. A flow from untrusted data into a sensitive sink is blocked unless the
//! data was endorsed along the way, an explicit act by a trusted authority (often a
//! person approving) that vouches for this specific data for this specific use.
//! Endorsement is the only bridge across the taint boundary, so nothing untrusted
//! crosses it by accident.
//!
//! This module moves no data. It decides whether a flow of given provenance may reach
//! a sink of given sensitivity, as a pure function over the taint and the sink.

const std = @import("std");

/// Where data came from, which sets whether it may be trusted to drive an effect.
pub const Provenance = enum {
    /// Produced by trusted system components or the person directly. Trusted.
    trusted,
    /// Came from outside — a fetched document, a model reading untrusted input, a
    /// third party. Untrusted until endorsed.
    untrusted,

    fn isTrusted(provenance: Provenance) bool {
        return provenance == .trusted;
    }
};

/// How consequential a sink is, which sets whether untrusted data may reach it.
pub const Sink = enum {
    /// Display or logging: shows data to the person, changes nothing in the world.
    /// Untrusted data may flow here freely.
    display,
    /// A local, reversible change: a draft, a note. Low consequence.
    local,
    /// A consequential effect: send, publish, pay, grant authority. Untrusted data
    /// must be endorsed to reach here.
    effect,

    fn isSensitive(sink: Sink) bool {
        return sink == .effect;
    }
};

/// Whether the data carries an endorsement — an explicit act by a trusted authority
/// vouching for this data for this use, the only bridge across the taint boundary.
pub const Endorsement = enum { none, endorsed };

/// Why a flow was blocked.
pub const Refusal = enum {
    /// Untrusted data attempted to reach a sensitive sink without endorsement.
    untrusted_to_sensitive,
};

/// The flow decision.
pub const Decision = union(enum) {
    allow,
    block: Refusal,

    pub fn allowed(decision: Decision) bool {
        return decision == .allow;
    }
};

/// Decides whether data of a given provenance may flow to a sink.
///
/// Trusted data flows anywhere. Untrusted data flows freely to sinks that only
/// display it or make a low-consequence local change, because reading and reasoning
/// over untrusted input is the whole point. Only when untrusted data reaches a
/// sensitive sink — one with real effect — is the flow blocked, and even then an
/// endorsement bridges it: an explicit vouching that lets this specific data through.
/// So the taint boundary is crossed only deliberately, never by accident.
pub fn decide(provenance: Provenance, sink: Sink, endorsement: Endorsement) Decision {
    if (provenance.isTrusted()) return .allow;
    if (!sink.isSensitive()) return .allow;
    if (endorsement == .endorsed) return .allow;
    return .{ .block = .untrusted_to_sensitive };
}

test "trusted data flows to any sink" {
    for ([_]Sink{ .display, .local, .effect }) |sink| {
        try std.testing.expect(decide(.trusted, sink, .none).allowed());
    }
}

test "untrusted data may be displayed and stored locally" {
    try std.testing.expect(decide(.untrusted, .display, .none).allowed());
    try std.testing.expect(decide(.untrusted, .local, .none).allowed());
}

test "untrusted data is blocked from a sensitive sink" {
    try std.testing.expectEqual(
        Decision{ .block = .untrusted_to_sensitive },
        decide(.untrusted, .effect, .none),
    );
}

test "an endorsement bridges untrusted data to a sensitive sink" {
    try std.testing.expect(decide(.untrusted, .effect, .endorsed).allowed());
}

test "endorsement is only needed at the sensitive boundary" {
    // For non-sensitive sinks, an endorsement is unnecessary and its absence is fine.
    try std.testing.expect(decide(.untrusted, .display, .none).allowed());
    try std.testing.expect(decide(.untrusted, .local, .none).allowed());
}

test "no untrusted data ever reaches a sensitive sink unendorsed, swept" {
    // The injection-defence property: whenever untrusted data is allowed to a
    // sensitive sink, it carried an endorsement.
    for ([_]Sink{ .display, .local, .effect }) |sink| {
        for ([_]Endorsement{ .none, .endorsed }) |endorsement| {
            const decision = decide(.untrusted, sink, endorsement);
            if (decision.allowed() and sink == .effect) {
                try std.testing.expectEqual(Endorsement.endorsed, endorsement);
            }
        }
    }
}
