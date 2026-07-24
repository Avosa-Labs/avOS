//! Deciding whether a request can be served by the on-device model, whose defining
//! property is that nothing about the request leaves the device.
//!
//! The local model is the private option: it runs on the device's own compute, so the
//! prompt, the context, and the answer never leave. That privacy is its whole value,
//! and it comes with a hard constraint — an on-device model is smaller, with a fixed
//! context window, so not every request fits. The routing decision here is honest
//! about that limit: a request whose input fits the local window is served locally and
//! stays entirely on the device, and one that does not fit is reported as too large,
//! so the caller can decide whether to trim it, split it, or fall back to a remote
//! model with the consent that off-device processing requires. What the local path
//! never does is silently truncate a request to make it fit, because a truncated
//! prompt is a different question, answered wrong. It serves what it can serve whole,
//! privately, and declines the rest plainly.
//!
//! This module runs no model. It decides whether a request fits the local model's
//! context window, as a pure function over the request size and the window.

const std = @import("std");

/// The on-device model's context window, in tokens. A fixed capacity a request's input
/// must fit within to be served locally.
pub const context_window_tokens: u32 = 4096;

/// A request considered for local serving.
pub const Request = struct {
    /// The request's input size in tokens.
    input_tokens: u32,
    /// The tokens it needs reserved for output. Input plus output must fit the window.
    output_tokens: u32,
};

/// The routing decision for the local model.
pub const Decision = union(enum) {
    /// The request fits and is served entirely on the device.
    serve_locally,
    /// The request does not fit the local context window; it must be trimmed, split,
    /// or routed elsewhere. Reported rather than truncated.
    too_large,

    pub fn local(decision: Decision) bool {
        return decision == .serve_locally;
    }
};

/// Decides whether a request can be served locally.
///
/// The input and reserved output together must fit the context window; if they do, the
/// request is served on the device and nothing leaves. If they do not, it is reported
/// as too large rather than truncated, because a silently shortened prompt is a
/// different, wrongly-answered question. The sum is computed in wide arithmetic so a
/// large request cannot wrap into an apparent fit.
pub fn route(request: Request) Decision {
    const needed = @as(u64, request.input_tokens) + request.output_tokens;
    if (needed <= context_window_tokens) return .serve_locally;
    return .too_large;
}

test "a request within the window is served locally" {
    try std.testing.expectEqual(Decision.serve_locally, route(.{ .input_tokens = 1000, .output_tokens = 500 }));
}

test "a request exceeding the window is too large" {
    try std.testing.expectEqual(Decision.too_large, route(.{ .input_tokens = 4000, .output_tokens = 500 }));
}

test "the window boundary is inclusive of input plus output" {
    try std.testing.expectEqual(
        Decision.serve_locally,
        route(.{ .input_tokens = context_window_tokens - 100, .output_tokens = 100 }),
    );
    try std.testing.expectEqual(
        Decision.too_large,
        route(.{ .input_tokens = context_window_tokens - 100, .output_tokens = 101 }),
    );
}

test "a huge request cannot wrap into an apparent fit" {
    try std.testing.expectEqual(
        Decision.too_large,
        route(.{ .input_tokens = std.math.maxInt(u32), .output_tokens = 10 }),
    );
}

test "no request over the window is ever served locally, swept" {
    // The honest-fit property: a locally-served request always fits input plus output
    // within the window.
    var input: u32 = 0;
    while (input <= context_window_tokens + 1000) : (input += 500) {
        const request: Request = .{ .input_tokens = input, .output_tokens = 200 };
        if (route(request).local()) {
            try std.testing.expect(@as(u64, input) + 200 <= context_window_tokens);
        }
    }
}
