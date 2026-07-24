//! The contract every model call goes through, bounding the output and marking it
//! untrusted, so a model's response is a proposal an agent evaluates, never an
//! instruction it obeys.
//!
//! A model is the engine inside an agent, and its output is the single most
//! misunderstood value in the system. It looks authoritative — fluent, confident,
//! shaped like an answer — and it is nothing of the sort: it is a proposal computed
//! over inputs that may include untrusted content, and treating it as trusted is the
//! root of every prompt-injection failure. So the model interface fixes two things
//! about every call, whatever backend serves it. The output is always tagged
//! untrusted, so anything derived from it inherits that taint and it can never reach a
//! consequential effect without passing the same endorsement gate any other untrusted
//! data would. And the output is bounded: a call declares a maximum size and the
//! interface holds it, because an unbounded generation is an unbounded cost and a way
//! to exhaust a budget. The interface is the one place these hold, so no backend can
//! quietly return trusted or unbounded output.
//!
//! This module calls no model. It decides whether a request is within its token bound
//! and fixes the provenance its output carries, as pure functions over the request.

const std = @import("std");

/// The provenance a model's output always carries. A model's output is a proposal
/// over its inputs, never trusted authority.
pub const output_provenance: Provenance = .untrusted;

/// How trusted a value is. The model interface only ever emits `untrusted` output.
pub const Provenance = enum { untrusted, trusted };

/// The hard ceiling on requested output tokens, whatever a caller asks for. A request
/// above this is refused rather than clamped, because a caller that needs more should
/// decompose the work, not silently receive less than it asked for.
pub const max_output_tokens: u32 = 8192;

/// A request to a model.
pub const Request = struct {
    /// The most output tokens the caller wants generated.
    max_tokens: u32,
};

/// Why a request was refused.
pub const Refusal = enum {
    /// Zero output tokens requested: not a real generation.
    empty_request,
    /// More output tokens requested than the interface allows.
    exceeds_token_ceiling,
};

/// The admission decision for a model call.
pub const Decision = union(enum) {
    /// The call may proceed, generating at most this many tokens; its output will be
    /// untrusted.
    admit: u32,
    refuse: Refusal,

    pub fn admitted(decision: Decision) bool {
        return decision == .admit;
    }
};

/// Decides whether a model request may proceed.
///
/// A zero-token request is not a generation and is refused. A request over the token
/// ceiling is refused rather than clamped, so a caller never silently gets less than
/// it asked for. An admitted request carries its own token bound as the generation
/// limit; whatever it produces is untrusted.
pub fn admit(request: Request) Decision {
    if (request.max_tokens == 0) return .{ .refuse = .empty_request };
    if (request.max_tokens > max_output_tokens) return .{ .refuse = .exceeds_token_ceiling };
    return .{ .admit = request.max_tokens };
}

/// The provenance any value derived from a model's output carries. Always untrusted:
/// this is the property that keeps model output from laundering into a trusted action.
pub fn outputProvenance() Provenance {
    return output_provenance;
}

test "a bounded request is admitted with its token limit" {
    try std.testing.expectEqual(Decision{ .admit = 1000 }, admit(.{ .max_tokens = 1000 }));
}

test "a zero-token request is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .empty_request }, admit(.{ .max_tokens = 0 }));
}

test "a request over the ceiling is refused, not clamped" {
    try std.testing.expectEqual(
        Decision{ .refuse = .exceeds_token_ceiling },
        admit(.{ .max_tokens = max_output_tokens + 1 }),
    );
}

test "the token ceiling is inclusive" {
    try std.testing.expect(admit(.{ .max_tokens = max_output_tokens }).admitted());
}

test "model output is always untrusted" {
    try std.testing.expectEqual(Provenance.untrusted, outputProvenance());
}

test "no admitted request ever exceeds the ceiling, swept" {
    // The bounded-output property: an admitted call's limit is always within the
    // ceiling.
    var tokens: u32 = 1;
    while (tokens <= max_output_tokens + 100) : (tokens += 500) {
        switch (admit(.{ .max_tokens = tokens })) {
            .admit => |limit| try std.testing.expect(limit <= max_output_tokens),
            .refuse => try std.testing.expect(tokens > max_output_tokens),
        }
    }
}
