//! Deciding whether a saved passkey is offered to a site, so a credential is presented only to the
//! exact relying party it belongs to and a phishing origin is met with nothing.
//!
//! A passkey is bound to a relying party — the site's identity — at the moment it is created, and its
//! phishing resistance is precisely that binding: the credential exists for one origin and must never
//! be usable at another. A person can be lured to a look-alike site, but the credential manager
//! cannot be, because the decision to offer a passkey turns not on how the page looks but on whether
//! the page's origin exactly matches the relying-party id the passkey was registered to, over a
//! secure connection. A request from any other origin — a homograph, a subdomain the passkey was not
//! registered for, an insecure page — is offered no passkey, so the secret that authenticates the
//! person to their real account is never even presented to the fake one. This is the property that
//! makes passkeys unphishable in a way passwords never were: there is no keystroke for the person to
//! misdirect, only an origin match the manager makes for them.
//!
//! This module signs nothing. It decides whether a passkey is offered for an authentication request,
//! from the registered relying party, the requesting origin, and the connection's security, as a pure
//! function.

const std = @import("std");

/// An authentication request from a page asking for a passkey.
pub const Request = struct {
    /// The relying-party id the passkey was registered to.
    registered_rp: []const u8,
    /// The origin (relying-party id) the requesting page presents.
    requesting_origin: []const u8,
    /// Whether the connection to the page is secure.
    connection_secure: bool,
};

/// Whether a saved passkey is offered for an authentication request.
///
/// The passkey is offered only when the requesting origin exactly matches the relying party the
/// passkey was registered to and the connection is secure. Any mismatch — a different origin, an
/// insecure connection — offers nothing, so a phishing page that merely resembles the real site is
/// never handed the credential.
pub fn mayOffer(request: Request) bool {
    return request.connection_secure and
        std.mem.eql(u8, request.registered_rp, request.requesting_origin);
}

fn makeRequest(registered: []const u8, requesting: []const u8, secure: bool) Request {
    return .{ .registered_rp = registered, .requesting_origin = requesting, .connection_secure = secure };
}

test "a passkey is offered to its exact relying party over a secure connection" {
    try std.testing.expect(mayOffer(makeRequest("bank.example", "bank.example", true)));
}

test "a mismatched origin is offered no passkey" {
    try std.testing.expect(!mayOffer(makeRequest("bank.example", "bank.example.evil", true)));
    try std.testing.expect(!mayOffer(makeRequest("bank.example", "evil.example", true)));
}

test "an insecure connection is offered no passkey" {
    try std.testing.expect(!mayOffer(makeRequest("bank.example", "bank.example", false)));
}

test "a passkey is offered only on an exact secure origin match, swept" {
    // The unphishability property: an offered passkey had a secure connection and an exact
    // relying-party match.
    const origins = [_][]const u8{ "bank.example", "bank.example.evil", "evil.example" };
    for (origins) |origin| {
        for ([_]bool{ false, true }) |secure| {
            const request = makeRequest("bank.example", origin, secure);
            if (mayOffer(request)) {
                try std.testing.expect(secure and std.mem.eql(u8, "bank.example", origin));
            }
        }
    }
}
