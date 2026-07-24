//! Deciding whether an approval prompt may still be acted on, so a person approves a held
//! action deliberately and a stale request cannot be approved after its moment has passed.
//!
//! The approval prompt is where the human-in-the-loop guarantee becomes real: an agent holds
//! a consequential action, and the person decides. For that decision to mean anything, the
//! prompt must be honest about what it authorizes and about time. A prompt is bound to one
//! specific action — approving it authorizes that action and nothing else — so a prompt whose
//! action changed underneath it is void, because a person who read one thing must not
//! approve another. And an approval request expires: a held action that has waited too long
//! is no longer something the person is deciding in context, and approving it late could
//! apply a decision to a situation that has moved on, so an expired prompt cannot be approved
//! and must be re-requested. A prompt that is neither stale nor mismatched may be approved,
//! once, and that approval authorizes exactly the action it named. These are the rules that
//! keep approval from being a rubber stamp.
//!
//! This module authorizes nothing. It decides whether an approval prompt may be acted on,
//! from its expiry and whether its bound action still matches, as a pure function.

const std = @import("std");

/// An approval prompt awaiting a decision.
pub const Prompt = struct {
    /// A digest of the exact action the prompt authorizes. Approval is bound to this.
    action_digest: u128,
    /// When the request was raised, in milliseconds since the epoch.
    requested_at_ms: i64,
    /// Whether the prompt has already been decided (approved or denied). A one-time
    /// decision.
    decided: bool = false,
};

/// How long an approval request stays valid, in milliseconds, before it is stale.
pub const validity_ms: i64 = 2 * 60 * 1000; // two minutes

/// Why an approval could not be acted on.
pub const Refusal = enum {
    /// The request has expired and must be re-requested.
    expired,
    /// The action changed since the prompt was raised; the prompt is void.
    action_mismatch,
    /// The prompt was already decided.
    already_decided,
};

/// The outcome of attempting to approve a prompt.
pub const Decision = union(enum) {
    /// The approval is valid and authorizes exactly the bound action.
    approve,
    refuse: Refusal,

    pub fn approves(decision: Decision) bool {
        return decision == .approve;
    }
};

/// Decides whether a prompt may be approved for a given current action, at a given time.
///
/// An already-decided prompt cannot be approved again — approval is one-time. A prompt whose
/// bound action digest does not match the action now being confirmed is void, so a person
/// never approves a changed action. A prompt older than its validity window has expired and
/// must be re-requested, so a stale decision is not applied to a moved-on situation. Only a
/// fresh, matching, undecided prompt approves, and it authorizes exactly the action it named.
pub fn decide(prompt: Prompt, current_action_digest: u128, now_ms: i64) Decision {
    if (prompt.decided) return .{ .refuse = .already_decided };
    if (prompt.action_digest != current_action_digest) return .{ .refuse = .action_mismatch };
    if (now_ms - prompt.requested_at_ms > validity_ms) return .{ .refuse = .expired };
    return .approve;
}

const digest: u128 = 0xABCDEF;
const t0: i64 = 1_000_000;

fn makePrompt(decided: bool) Prompt {
    return .{ .action_digest = digest, .requested_at_ms = t0, .decided = decided };
}

test "a fresh matching prompt approves" {
    try std.testing.expect(decide(makePrompt(false), digest, t0 + 1000).approves());
}

test "an already-decided prompt cannot be approved again" {
    try std.testing.expectEqual(Decision{ .refuse = .already_decided }, decide(makePrompt(true), digest, t0 + 1000));
}

test "a prompt whose action changed is void" {
    try std.testing.expectEqual(Decision{ .refuse = .action_mismatch }, decide(makePrompt(false), 0xBADBAD, t0 + 1000));
}

test "an expired prompt cannot be approved" {
    try std.testing.expectEqual(Decision{ .refuse = .expired }, decide(makePrompt(false), digest, t0 + validity_ms + 1));
}

test "the validity boundary is inclusive" {
    try std.testing.expect(decide(makePrompt(false), digest, t0 + validity_ms).approves());
    try std.testing.expect(!decide(makePrompt(false), digest, t0 + validity_ms + 1).approves());
}

test "no mismatched action is ever approved, swept" {
    // The bound-action property: an approval only ever happens when the current action
    // matches the bound digest.
    const actions = [_]u128{ digest, 0x111, 0x222 };
    for (actions) |action| {
        if (decide(makePrompt(false), action, t0 + 1000).approves()) {
            try std.testing.expectEqual(digest, action);
        }
    }
}

test "no stale prompt is ever approved, swept" {
    var elapsed: i64 = 0;
    while (elapsed <= validity_ms * 2) : (elapsed += validity_ms / 4) {
        if (decide(makePrompt(false), digest, t0 + elapsed).approves()) {
            try std.testing.expect(elapsed <= validity_ms);
        }
    }
}
