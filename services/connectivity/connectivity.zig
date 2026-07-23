//! Deciding whether an outbound transfer proceeds now, waits, or needs the person's
//! say-so, given what the connection costs, so the device never spends a person's
//! money or data allowance on their behalf without asking.
//!
//! Not all connectivity is free. A metered cellular link costs money by the byte,
//! a roaming link costs more, and a data plan has a cap a person does not want a
//! background sync to blow through. Reachability decides which link a request can
//! take and the firewall decides whether it is allowed to leave at all; what is
//! left is the question of cost, and it is the person's question, not the device's.
//! So a transfer's fate depends on two things it does not itself control: how much
//! the connection costs and how deferrable the transfer is. Small interactive work
//! a person is waiting on proceeds even when metered, because making them wait to
//! save pennies is its own cost; bulk deferrable work waits for a free link; and a
//! large transfer that would spend real money on a metered link is held for the
//! person to approve rather than run silently.
//!
//! This module moves no bytes. It decides proceed, defer, or ask, as a pure
//! function over the connection's cost and the transfer's size and urgency.

const std = @import("std");

/// What the active connection costs.
pub const Cost = enum {
    /// Unmetered: bytes are free. Anything may proceed.
    unmetered,
    /// Metered: bytes cost money or count against a cap.
    metered,
    /// Roaming: metered, and typically far more expensive.
    roaming,

    fn isMetered(cost: Cost) bool {
        return cost != .unmetered;
    }
};

/// How deferrable a transfer is, which sets how much connection cost it tolerates.
pub const Urgency = enum {
    /// Interactive: a person is waiting on it now. Proceeds on any link — making
    /// them wait to save a few bytes is the worse outcome.
    interactive,
    /// Deferrable bulk: a backup, a large prefetch. Waits for an unmetered link.
    deferrable,
};

/// The size, in bytes, at or above which a metered transfer is large enough to be
/// worth a person's explicit approval rather than run silently.
pub const consent_threshold_bytes: u64 = 50 * 1024 * 1024;

/// A transfer awaiting a decision.
pub const Transfer = struct {
    size_bytes: u64,
    urgency: Urgency,
};

/// What to do with a transfer.
pub const Decision = enum {
    /// Proceed now.
    proceed,
    /// Wait for a cheaper connection.
    defer_until_unmetered,
    /// Hold for the person to approve spending on this connection.
    ask_consent,

    pub fn proceeds(decision: Decision) bool {
        return decision == .proceed;
    }
};

/// Decides what to do with a transfer on a connection.
///
/// On an unmetered link everything proceeds. On a metered link, deferrable bulk
/// work waits for a free link rather than spending; interactive work a person is
/// waiting on proceeds if it is small, but a transfer at or above the consent
/// threshold is held for approval, because spending real money silently is the
/// thing a person must get to veto. The size gate applies only to metered links —
/// on a free link, size does not matter.
pub fn decide(transfer: Transfer, cost: Cost) Decision {
    if (!cost.isMetered()) return .proceed;

    switch (transfer.urgency) {
        .deferrable => return .defer_until_unmetered,
        .interactive => {
            if (transfer.size_bytes >= consent_threshold_bytes) return .ask_consent;
            return .proceed;
        },
    }
}

fn makeTransfer(size: u64, urgency: Urgency) Transfer {
    return .{ .size_bytes = size, .urgency = urgency };
}

const small: u64 = 1024;
const large: u64 = consent_threshold_bytes;

test "everything proceeds on an unmetered link" {
    try std.testing.expect(decide(makeTransfer(large, .deferrable), .unmetered).proceeds());
    try std.testing.expect(decide(makeTransfer(large, .interactive), .unmetered).proceeds());
}

test "deferrable bulk waits on a metered link" {
    try std.testing.expectEqual(Decision.defer_until_unmetered, decide(makeTransfer(large, .deferrable), .metered));
    try std.testing.expectEqual(Decision.defer_until_unmetered, decide(makeTransfer(small, .deferrable), .roaming));
}

test "small interactive work proceeds even when metered" {
    try std.testing.expect(decide(makeTransfer(small, .interactive), .metered).proceeds());
    try std.testing.expect(decide(makeTransfer(small, .interactive), .roaming).proceeds());
}

test "a large interactive transfer on a metered link asks consent" {
    try std.testing.expectEqual(Decision.ask_consent, decide(makeTransfer(large, .interactive), .metered));
    try std.testing.expectEqual(Decision.ask_consent, decide(makeTransfer(large, .interactive), .roaming));
}

test "the consent threshold is inclusive" {
    try std.testing.expectEqual(Decision.ask_consent, decide(makeTransfer(consent_threshold_bytes, .interactive), .metered));
    try std.testing.expect(decide(makeTransfer(consent_threshold_bytes - 1, .interactive), .metered).proceeds());
}

test "no large metered spend ever proceeds silently, swept" {
    // The no-silent-spend property: on any metered link, a transfer at or above the
    // threshold is never a bare proceed.
    for ([_]Cost{ .metered, .roaming }) |cost| {
        for ([_]Urgency{ .interactive, .deferrable }) |urgency| {
            const decision = decide(makeTransfer(consent_threshold_bytes, urgency), cost);
            try std.testing.expect(!decision.proceeds());
        }
    }
}

test "no deferrable work ever spends on a metered link, swept" {
    var size: u64 = 0;
    while (size <= large * 2) : (size += large / 4 + 1) {
        for ([_]Cost{ .metered, .roaming }) |cost| {
            try std.testing.expectEqual(Decision.defer_until_unmetered, decide(makeTransfer(size, .deferrable), cost));
        }
    }
}
