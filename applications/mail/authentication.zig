//! Deciding whether an email's claimed sender is trustworthy, so a message forging a known
//! organization's address is marked unverified rather than presented as genuine.
//!
//! The address in an email's From line is a claim, not a fact — anyone can write "your bank" in it.
//! The defence is sender authentication: the receiving side checks that the message was actually
//! authorized by the domain it claims to come from. A message passes only when its cryptographic
//! signature verifies and the signing domain aligns with the visible From domain — the two together,
//! because a valid signature for some other domain proves nothing about the sender the person sees.
//! A message that fails either check is not necessarily deleted, but it is marked unverified and its
//! links and requests are not treated as coming from the named sender, because that is exactly the
//! shape of a phishing message: a real-looking From line with no authorization behind it. Presenting
//! only aligned, verified mail as coming from whom it claims is what stops a forged address from
//! borrowing an organization's trust.
//!
//! This module delivers no mail. It decides whether a message's claimed sender is authenticated,
//! from its signature validity and domain alignment, as a pure function.

const std = @import("std");

/// The authentication signals gathered for an incoming message.
pub const Message = struct {
    /// Whether the message's cryptographic (DKIM-style) signature verified.
    signature_valid: bool,
    /// Whether the signing domain aligns with the visible From domain (DMARC-style alignment).
    domain_aligned: bool,
};

/// Whether an email's claimed sender is authenticated.
///
/// Both signals must hold: the signature verifies and the signing domain aligns with the From
/// address the person sees. Either failing marks the message unverified, so a forged From line —
/// which can have at most one of these, and usually neither — is never presented as the genuine
/// sender.
pub fn authenticated(message: Message) bool {
    return message.signature_valid and message.domain_aligned;
}

fn makeMessage(signature: bool, aligned: bool) Message {
    return .{ .signature_valid = signature, .domain_aligned = aligned };
}

test "a signed, aligned message is authenticated" {
    try std.testing.expect(authenticated(makeMessage(true, true)));
}

test "a valid signature for a misaligned domain is not authenticated" {
    try std.testing.expect(!authenticated(makeMessage(true, false)));
}

test "an unsigned message is not authenticated" {
    try std.testing.expect(!authenticated(makeMessage(false, true)));
    try std.testing.expect(!authenticated(makeMessage(false, false)));
}

test "authentication requires both signals, swept" {
    // The forgery-resistance property: an authenticated message had both a valid signature and
    // domain alignment.
    for ([_]bool{ false, true }) |signature| {
        for ([_]bool{ false, true }) |aligned| {
            if (authenticated(makeMessage(signature, aligned))) {
                try std.testing.expect(signature and aligned);
            }
        }
    }
}
