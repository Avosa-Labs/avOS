//! Deciding whether a request may be sent to a remote model, because doing so is data
//! leaving the device, so a secret never goes and sensitive content goes only with
//! consent.
//!
//! A remote model is more capable than the on-device one, and reaching it means sending
//! the prompt off the device to a third party's servers. That is an egress event before
//! it is a capability decision, and it is governed by what the content is. Some content
//! must never leave in a prompt at all — a private key, a credential, a device-bound
//! secret — because no answer a remote model could give is worth exfiltrating a secret,
//! and the request is refused outright. Some content is sensitive — a person's private
//! documents, their messages — and may be sent, but only with the person's consent,
//! because sending it to a third party is a disclosure they must agree to. And ordinary
//! content is sent freely, since routing a non-sensitive question to a better model is
//! exactly the point. The remote path is the powerful option gated by disclosure, so
//! capability never quietly overrides privacy.
//!
//! This module sends nothing. It decides send, hold-for-consent, or refuse from the
//! sensitivity of the request's content and whether consent was given, as a pure
//! function.

const std = @import("std");

/// How sensitive the content of a request is, which governs whether it may leave the
/// device.
pub const Sensitivity = enum {
    /// Ordinary content: a general question, public information. May be sent freely.
    ordinary,
    /// The person's private data: documents, messages, personal context. Sent only
    /// with consent.
    sensitive,
    /// A secret: a key, a credential, a device-bound token. Never sent, at all.
    secret,
};

/// Whether the person has consented to this off-device send.
pub const Consent = enum { none, granted };

/// A request considered for a remote model.
pub const Request = struct {
    sensitivity: Sensitivity,
};

/// Why a remote send was refused.
pub const Refusal = enum {
    /// The content is a secret; it never leaves the device.
    secret_never_leaves,
};

/// The routing decision for the remote model.
pub const Decision = union(enum) {
    /// The request may be sent to the remote model.
    send,
    /// The request may be sent, but the person must consent to the disclosure first.
    hold_for_consent,
    /// The request is refused; it must not leave the device.
    refuse: Refusal,

    pub fn sends(decision: Decision) bool {
        return decision == .send;
    }
};

/// Decides whether a request may be sent to a remote model.
///
/// A secret is refused outright — no remote answer justifies exfiltrating it. Sensitive
/// content may be sent, but only once the person has consented to the disclosure;
/// without consent it is held. Ordinary content is sent freely. So capability never
/// silently overrides privacy: the more sensitive the content, the more the send is
/// gated, and a secret is never gated open at all.
pub fn route(request: Request, consent: Consent) Decision {
    return switch (request.sensitivity) {
        .secret => .{ .refuse = .secret_never_leaves },
        .sensitive => if (consent == .granted) .send else .hold_for_consent,
        .ordinary => .send,
    };
}

test "ordinary content is sent freely" {
    try std.testing.expectEqual(Decision.send, route(.{ .sensitivity = .ordinary }, .none));
    try std.testing.expectEqual(Decision.send, route(.{ .sensitivity = .ordinary }, .granted));
}

test "sensitive content is held without consent and sent with it" {
    try std.testing.expectEqual(Decision.hold_for_consent, route(.{ .sensitivity = .sensitive }, .none));
    try std.testing.expectEqual(Decision.send, route(.{ .sensitivity = .sensitive }, .granted));
}

test "a secret is never sent, with or without consent" {
    try std.testing.expectEqual(Decision{ .refuse = .secret_never_leaves }, route(.{ .sensitivity = .secret }, .none));
    try std.testing.expectEqual(Decision{ .refuse = .secret_never_leaves }, route(.{ .sensitivity = .secret }, .granted));
}

test "no secret ever leaves the device, swept" {
    // The no-exfiltration property: a secret is refused whatever the consent state.
    for ([_]Consent{ .none, .granted }) |consent| {
        try std.testing.expect(!route(.{ .sensitivity = .secret }, consent).sends());
    }
}

test "sensitive content never leaves without consent, swept" {
    // A sensitive send only ever happens with consent granted.
    for ([_]Consent{ .none, .granted }) |consent| {
        if (route(.{ .sensitivity = .sensitive }, consent).sends()) {
            try std.testing.expectEqual(Consent.granted, consent);
        }
    }
}
