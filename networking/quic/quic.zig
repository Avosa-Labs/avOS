//! Deciding how much a server may send to an unvalidated address and what an
//! early-data request may carry, so a connection cannot be turned into an
//! amplifier or replayed into a repeated side effect.
//!
//! QUIC establishes connections over UDP, which brings two hazards that TCP's
//! handshake happened to prevent, and both need a decision the packet code should
//! not improvise. The first is amplification: a UDP source address is trivially
//! spoofed, so an attacker sends a small packet claiming a victim's address and, if
//! the server replies with much more than it received, the server becomes a weapon
//! aimed at the victim. The defence is a hard limit — a server may send no more
//! than a small multiple of what it has received from an address until that
//! address is validated. The second is replay: QUIC's 0-RTT feature lets a client
//! send request data in its very first flight, before the handshake completes,
//! which an attacker can capture and resend. That is harmless for a request with no
//! side effect and dangerous for one that has them, so early data may carry only
//! idempotent requests.
//!
//! This module moves no packets. It answers how many bytes may still be sent to an
//! unvalidated address, and whether a given request may travel as 0-RTT early data,
//! as pure functions over the connection's counters and the request's method.

const std = @import("std");

/// The multiple of received bytes a server may send to an address before that
/// address is validated. Three is the value QUIC specifies: enough to complete a
/// handshake, small enough that the server is a poor amplifier.
pub const amplification_factor: u32 = 3;

/// The address-validation state of a connection.
pub const AddressState = enum {
    /// The peer's address has not been confirmed reachable — it may be spoofed.
    /// The amplification limit applies.
    unvalidated,
    /// The address has been validated, by a returned token or a completed
    /// handshake. The limit no longer applies.
    validated,
};

/// The send-side counters for one connection, used to enforce the amplification
/// limit.
pub const SendBudget = struct {
    state: AddressState = .unvalidated,
    /// Bytes received from the peer's address so far.
    received: u64 = 0,
    /// Bytes already sent to that address in this connection.
    sent: u64 = 0,

    /// How many more bytes the server may send right now.
    ///
    /// A validated address has no limit — the reflection risk is gone once the
    /// peer has proven it receives what is sent. An unvalidated address may be
    /// sent at most the amplification factor times what it has sent us, less what
    /// we have already sent, saturating at zero so the budget never goes negative
    /// and never lets a burst exceed the cap.
    pub fn remaining(budget: SendBudget) u64 {
        if (budget.state == .validated) return std.math.maxInt(u64);
        const ceiling = budget.received *| amplification_factor;
        return ceiling -| budget.sent;
    }

    /// Whether a datagram of `bytes` may be sent without breaching the limit.
    pub fn maySend(budget: SendBudget, bytes: u64) bool {
        return bytes <= budget.remaining();
    }

    /// Records bytes received from the peer, which raises the ceiling.
    pub fn recordReceived(budget: *SendBudget, bytes: u64) void {
        budget.received +|= bytes;
    }

    /// Records bytes sent to the peer, which spends the budget.
    pub fn recordSent(budget: *SendBudget, bytes: u64) void {
        budget.sent +|= bytes;
    }

    /// Marks the address validated, lifting the limit.
    pub fn validate(budget: *SendBudget) void {
        budget.state = .validated;
    }
};

/// An HTTP-style method carried by a request, classified by whether repeating it
/// is safe. Mirrors the idempotency notion the HTTP layer uses, kept here so the
/// 0-RTT decision does not reach across modules.
pub const Method = enum {
    get,
    head,
    options,
    put,
    delete,
    post,
    patch,

    /// Whether issuing the method twice leaves the same state as issuing it once.
    /// Only idempotent requests are safe to carry as replayable early data.
    pub fn isIdempotent(method: Method) bool {
        return switch (method) {
            .get, .head, .options, .put, .delete => true,
            .post, .patch => false,
        };
    }
};

/// Whether a request may be sent as 0-RTT early data.
///
/// Early data can be captured and replayed by an attacker before the handshake
/// that would detect the replay completes, so it may carry only a request that is
/// safe to apply more than once. A non-idempotent request must wait for the
/// handshake to complete and travel as ordinary 1-RTT data, where the replay
/// protection is in force.
pub fn mayUseEarlyData(method: Method) bool {
    return method.isIdempotent();
}

test "an unvalidated address may be sent up to the amplification factor" {
    var budget: SendBudget = .{};
    budget.recordReceived(100);
    // Three times 100 received, nothing sent yet.
    try std.testing.expectEqual(@as(u64, 300), budget.remaining());
    try std.testing.expect(budget.maySend(300));
    try std.testing.expect(!budget.maySend(301));
}

test "the budget is spent as bytes are sent" {
    var budget: SendBudget = .{};
    budget.recordReceived(100);
    budget.recordSent(250);
    try std.testing.expectEqual(@as(u64, 50), budget.remaining());
    try std.testing.expect(budget.maySend(50));
    try std.testing.expect(!budget.maySend(51));
}

test "the budget never goes negative when more was somehow sent than allowed" {
    var budget: SendBudget = .{};
    budget.recordReceived(10);
    budget.recordSent(1000); // beyond the ceiling
    try std.testing.expectEqual(@as(u64, 0), budget.remaining());
    try std.testing.expect(!budget.maySend(1));
}

test "receiving more from the peer raises the ceiling" {
    var budget: SendBudget = .{};
    budget.recordReceived(100);
    budget.recordSent(300); // spent the initial budget
    try std.testing.expectEqual(@as(u64, 0), budget.remaining());
    budget.recordReceived(100); // peer sent more
    try std.testing.expectEqual(@as(u64, 300), budget.remaining());
}

test "a validated address has no amplification limit" {
    var budget: SendBudget = .{ .received = 1 };
    budget.validate();
    try std.testing.expect(budget.maySend(std.math.maxInt(u64)));
}

test "an unvalidated address with nothing received may send nothing" {
    // Before the peer has sent anything, the server may not send at all: the limit
    // is three times zero.
    const budget: SendBudget = .{};
    try std.testing.expectEqual(@as(u64, 0), budget.remaining());
    try std.testing.expect(!budget.maySend(1));
}

test "idempotent methods may travel as early data" {
    try std.testing.expect(mayUseEarlyData(.get));
    try std.testing.expect(mayUseEarlyData(.put));
    try std.testing.expect(mayUseEarlyData(.delete));
}

test "non-idempotent methods may not travel as early data" {
    // A replayed POST could apply twice; it waits for the handshake.
    try std.testing.expect(!mayUseEarlyData(.post));
    try std.testing.expect(!mayUseEarlyData(.patch));
}

test "a server never sends more than the factor times received while unvalidated, swept" {
    // The anti-amplification property. Across a range of received amounts, the
    // most that may ever be sent is the factor times what was received.
    var received: u64 = 0;
    while (received <= 1000) : (received += 100) {
        const budget: SendBudget = .{ .received = received };
        try std.testing.expectEqual(received * amplification_factor, budget.remaining());
        try std.testing.expect(!budget.maySend(received * amplification_factor + 1));
    }
}
