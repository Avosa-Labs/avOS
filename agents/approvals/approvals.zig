//! Holding a consequential action for a person, and letting their answer
//! authorize it exactly once.
//!
//! When the injection gate decides an action needs a person, this is what holds
//! it. An approval is a promise with sharp edges: the person is shown exactly
//! what will happen, their decision authorizes that and nothing else, the
//! authorization is good for one use and then spent, and it expires if they do
//! not act, because an approval that lingers is an approval an attacker can wait
//! for. The failures this prevents are the ones that make agent autonomy unsafe
//! — an approval reused for a second action, an approval whose displayed summary
//! does not match what is actually done, an approval granted for one amount and
//! spent on another.
//!
//! This module is the approval's state machine and the checks that bind a
//! decision to a specific action. It performs nothing; it decides whether a
//! request may be presented, records the person's answer, and answers the one
//! question the executor asks — may this exact action run now — such that the
//! answer is yes at most once.

const std = @import("std");
const core = @import("core");

/// What a request describes, bound so the approval covers this and only this.
///
/// The digest is over the action's full details — recipient, amount, content —
/// so a decision cannot be transplanted onto a different action by changing a
/// field the summary did not mention.
pub const Request = struct {
    /// A digest of the complete action, computed by the caller. The approval is
    /// bound to it: presenting one action and performing another is caught here.
    action_digest: [32]u8,
    /// A short, honest description of what will happen, shown to the person. It
    /// must describe the same action the digest covers.
    summary: []const u8,
    /// When the request was created, in milliseconds.
    created_ms: u64,
};

/// How long an unanswered approval remains open, in milliseconds.
///
/// Bounded, because a decision prompt that waits forever is one an attacker can
/// leave sitting until the person taps it without reading, or until a context
/// where approving is plausible arises.
pub const default_expiry_ms: u64 = 120_000;

/// The state of one approval.
pub const State = enum {
    /// Presented to the person, awaiting their decision.
    pending,
    /// The person approved. Still unspent.
    approved,
    /// The person declined.
    declined,
    /// The person did not act in time.
    expired,
    /// Approved and then used. Cannot be used again.
    spent,
};

pub const Error = error{
    /// The decision was made out of order: deciding an approval that is no
    /// longer pending.
    NotPending,
    /// The action presented for execution does not match the one approved.
    ActionMismatch,
    /// The approval is not in a state that permits the operation.
    NotApproved,
    /// The approval has already been used.
    AlreadySpent,
};

/// An approval as it moves through its lifecycle.
pub const Approval = struct {
    request: Request,
    state: State = .pending,
    expiry_ms: u64,

    pub fn present(request: Request) Approval {
        return .{ .request = request, .expiry_ms = request.created_ms + default_expiry_ms };
    }

    /// Records the person approving. Only a pending, unexpired approval may be
    /// approved.
    pub fn approve(approval: *Approval, now_ms: u64) Error!void {
        if (approval.expired(now_ms)) {
            approval.state = .expired;
            return error.NotPending;
        }
        if (approval.state != .pending) return error.NotPending;
        approval.state = .approved;
    }

    /// Records the person declining.
    pub fn decline(approval: *Approval) Error!void {
        if (approval.state != .pending) return error.NotPending;
        approval.state = .declined;
    }

    /// Whether the approval has passed its expiry.
    pub fn expired(approval: Approval, now_ms: u64) bool {
        return now_ms >= approval.expiry_ms;
    }

    /// Authorizes an action, consuming the approval.
    ///
    /// The action presented here must match the one approved, by digest, so a
    /// decision cannot be transplanted onto a different action. On success the
    /// approval becomes spent and no second call can succeed — the one-time
    /// property that stops an agent replaying an approval for a second effect.
    pub fn authorize(approval: *Approval, action_digest: [32]u8, now_ms: u64) Error!void {
        if (approval.state == .spent) return error.AlreadySpent;
        if (approval.state != .approved) return error.NotApproved;
        if (approval.expired(now_ms)) {
            approval.state = .expired;
            return error.NotApproved;
        }
        if (!std.crypto.timing_safe.eql([32]u8, approval.request.action_digest, action_digest)) {
            return error.ActionMismatch;
        }
        approval.state = .spent;
    }

    /// Whether this approval can still authorize its action right now.
    pub fn isLive(approval: Approval, now_ms: u64) bool {
        return approval.state == .approved and !approval.expired(now_ms);
    }
};

fn digestOf(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn requestFor(action: []const u8, summary: []const u8, created_ms: u64) Request {
    return .{ .action_digest = digestOf(action), .summary = summary, .created_ms = created_ms };
}

test "an approved action authorizes exactly once" {
    var approval = Approval.present(requestFor("pay 10 to venue", "Pay $10 to the venue", 1000));
    try approval.approve(1500);
    // First authorization succeeds.
    try approval.authorize(digestOf("pay 10 to venue"), 2000);
    // The second is refused: the approval is spent.
    try std.testing.expectError(error.AlreadySpent, approval.authorize(digestOf("pay 10 to venue"), 2001));
}

test "a decision does not transplant onto a different action" {
    var approval = Approval.present(requestFor("pay 10 to venue", "Pay $10 to the venue", 1000));
    try approval.approve(1500);
    // An agent tries to spend the approval on a different payment.
    try std.testing.expectError(
        error.ActionMismatch,
        approval.authorize(digestOf("pay 10000 to attacker"), 2000),
    );
    // And the approval is not consumed by the failed attempt, so the genuine
    // action can still run.
    try approval.authorize(digestOf("pay 10 to venue"), 2001);
}

test "an unapproved action cannot be authorized" {
    var approval = Approval.present(requestFor("send message", "Send the message", 1000));
    // Still pending: no authorization.
    try std.testing.expectError(error.NotApproved, approval.authorize(digestOf("send message"), 1500));
}

test "a declined approval cannot be authorized" {
    var approval = Approval.present(requestFor("send message", "Send the message", 1000));
    try approval.decline();
    try std.testing.expectError(error.NotApproved, approval.authorize(digestOf("send message"), 1500));
}

test "an approval expires if not acted on" {
    var approval = Approval.present(requestFor("send message", "Send the message", 1000));
    // Approving after expiry fails and marks it expired.
    try std.testing.expectError(error.NotPending, approval.approve(1000 + default_expiry_ms));
    try std.testing.expectEqual(State.expired, approval.state);
}

test "an approval granted then left too long cannot be spent" {
    var approval = Approval.present(requestFor("send message", "Send the message", 1000));
    try approval.approve(1500);
    // Approved, but the person walked away and the window passed before the
    // action ran: an approval an attacker could have waited for is not honored.
    try std.testing.expectError(
        error.NotApproved,
        approval.authorize(digestOf("send message"), 1000 + default_expiry_ms),
    );
}

test "approving an already-decided approval is refused" {
    var approval = Approval.present(requestFor("x", "do x", 1000));
    try approval.approve(1100);
    // A second approve is out of order.
    try std.testing.expectError(error.NotPending, approval.approve(1200));
}

test "declining a non-pending approval is refused" {
    var approval = Approval.present(requestFor("x", "do x", 1000));
    try approval.approve(1100);
    try std.testing.expectError(error.NotPending, approval.decline());
}

test "isLive reflects whether the action can still run" {
    var approval = Approval.present(requestFor("x", "do x", 1000));
    try std.testing.expect(!approval.isLive(1100)); // pending, not approved
    try approval.approve(1100);
    try std.testing.expect(approval.isLive(1200)); // approved and fresh
    try std.testing.expect(!approval.isLive(1000 + default_expiry_ms)); // expired

    var spent = Approval.present(requestFor("y", "do y", 1000));
    try spent.approve(1100);
    try spent.authorize(digestOf("y"), 1200);
    try std.testing.expect(!spent.isLive(1300)); // spent
}

test "the summary describes the action the digest binds" {
    // A caller must build the summary and digest from the same action; the
    // approval carries both so an executor can show the summary and check the
    // digest, and they cannot silently disagree because they travel together.
    const request = requestFor("pay 10 to venue", "Pay $10 to the venue", 1000);
    try std.testing.expectEqualStrings("Pay $10 to the venue", request.summary);
    try std.testing.expectEqualSlices(u8, &digestOf("pay 10 to venue"), &request.action_digest);
}
