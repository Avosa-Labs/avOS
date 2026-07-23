//! Deciding whether an incoming call rings, is silenced, or is blocked, so a person
//! is reached by the calls that matter and not harassed by the ones that do not.
//!
//! An incoming call is an interruption a stranger initiates, and unscreened it is a
//! channel for spam and fraud that rings through every quiet moment. Screening
//! decides its fate from two things: what is known about the caller, and what the
//! person has asked for. A known contact is always put through, because the whole
//! point of a phone is that the people who matter can reach it. A number known to be
//! a spammer or a scam is blocked outright. An unknown number is where policy lives:
//! a person who wants no unknown callers has them silenced to voicemail, while one
//! who does not is rung normally. The one line screening never crosses is an
//! emergency callback — a call back from a number the person just dialled for help
//! rings through everything, because silencing it could cost a life.
//!
//! This module places and answers nothing. It decides ring, silence, or block from
//! the caller's reputation, the person's policy, and whether the call is an
//! emergency callback, as a pure function over those inputs.

const std = @import("std");

/// What is known about the calling number.
pub const Reputation = enum {
    /// A saved contact. Always rings.
    contact,
    /// Not a contact and not flagged: an ordinary unknown number.
    unknown,
    /// Known to be spam or fraud. Blocked.
    flagged_spam,
};

/// The person's policy for unknown callers.
pub const UnknownPolicy = enum {
    /// Ring unknown numbers normally.
    allow,
    /// Send unknown numbers straight to voicemail without ringing.
    silence,
};

/// What to do with an incoming call.
pub const Disposition = enum {
    /// Ring the person.
    ring,
    /// Do not ring; route to voicemail.
    silence,
    /// Reject the call outright.
    block,
};

/// An incoming call.
pub const Call = struct {
    reputation: Reputation,
    /// Whether this is a callback from a number the person just dialled for
    /// emergency help. Overrides all screening.
    emergency_callback: bool = false,
};

/// Decides the disposition of an incoming call.
///
/// An emergency callback rings through everything first, because silencing a call
/// back from help could be fatal. Otherwise a flagged spam number is blocked, a
/// saved contact always rings, and an unknown number follows the person's policy —
/// rung if they allow unknown callers, silenced to voicemail if they do not.
pub fn screen(call: Call, policy: UnknownPolicy) Disposition {
    if (call.emergency_callback) return .ring;
    return switch (call.reputation) {
        .flagged_spam => .block,
        .contact => .ring,
        .unknown => switch (policy) {
            .allow => .ring,
            .silence => .silence,
        },
    };
}

test "a contact always rings" {
    try std.testing.expectEqual(Disposition.ring, screen(.{ .reputation = .contact }, .allow));
    try std.testing.expectEqual(Disposition.ring, screen(.{ .reputation = .contact }, .silence));
}

test "flagged spam is blocked" {
    try std.testing.expectEqual(Disposition.block, screen(.{ .reputation = .flagged_spam }, .allow));
    try std.testing.expectEqual(Disposition.block, screen(.{ .reputation = .flagged_spam }, .silence));
}

test "an unknown number follows the person's policy" {
    try std.testing.expectEqual(Disposition.ring, screen(.{ .reputation = .unknown }, .allow));
    try std.testing.expectEqual(Disposition.silence, screen(.{ .reputation = .unknown }, .silence));
}

test "an emergency callback rings through every screening state" {
    // Even a number flagged as spam, under a silence-unknown policy, rings if it is
    // an emergency callback.
    for ([_]Reputation{ .contact, .unknown, .flagged_spam }) |reputation| {
        for ([_]UnknownPolicy{ .allow, .silence }) |policy| {
            const call: Call = .{ .reputation = reputation, .emergency_callback = true };
            try std.testing.expectEqual(Disposition.ring, screen(call, policy));
        }
    }
}

test "a contact is never blocked or silenced, swept" {
    for ([_]UnknownPolicy{ .allow, .silence }) |policy| {
        try std.testing.expectEqual(Disposition.ring, screen(.{ .reputation = .contact }, policy));
    }
}

test "spam is never rung unless it is an emergency callback, swept" {
    // The harassment-prevention property: a flagged number rings only when it is an
    // emergency callback.
    for ([_]UnknownPolicy{ .allow, .silence }) |policy| {
        for ([_]bool{ false, true }) |callback| {
            const disposition = screen(.{ .reputation = .flagged_spam, .emergency_callback = callback }, policy);
            if (disposition == .ring) try std.testing.expect(callback);
        }
    }
}
