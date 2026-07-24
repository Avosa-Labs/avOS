//! Deciding whether a saved password is offered on a page, so a credential is filled only on the
//! exact site it belongs to and a look-alike phishing page gets nothing.
//!
//! Phishing works because a page can be made to look like a bank's login while living at a different
//! address. A person can be fooled by the pixels; the browser must not be fooled by them. So the
//! decision to offer a saved credential turns on the page's origin — its scheme and host — matching
//! the origin the credential was saved for, exactly, with no allowance for a suffix or look-alike
//! host. A saved login for a bank is offered on that bank's origin over a secure connection and
//! nowhere else: not on a subdomain it was not saved for, not on a homograph host, not over plain
//! transport where the page and the filled secret could be observed. The person's eyes can be
//! deceived by a convincing copy; anchoring autofill to an exact origin match means the copy simply
//! never receives the password, which is what makes a saved credential phishing-resistant rather
//! than a liability.
//!
//! This module fills nothing. It decides whether a saved credential is offered on a page, from the
//! saved origin, the page origin, and the connection's security, as a pure function.

const std = @import("std");

/// A web origin: scheme and host, the identity a credential is bound to.
pub const Origin = struct {
    scheme: []const u8,
    host: []const u8,

    fn matches(origin: Origin, other: Origin) bool {
        return std.mem.eql(u8, origin.scheme, other.scheme) and std.mem.eql(u8, origin.host, other.host);
    }
};

/// Whether a saved credential is offered for autofill on the current page.
///
/// The credential is offered only when the page's origin exactly matches the origin the credential
/// was saved for and the connection is secure. Any mismatch — a different host, a different scheme,
/// an insecure connection — withholds it, so a page impersonating a site the person has a login for
/// cannot elicit that login by resembling it.
pub fn mayOffer(saved_origin: Origin, page_origin: Origin, connection_secure: bool) bool {
    return connection_secure and saved_origin.matches(page_origin);
}

test "a saved credential is offered on its exact origin over a secure connection" {
    const saved = Origin{ .scheme = "https", .host = "bank.example" };
    try std.testing.expect(mayOffer(saved, saved, true));
}

test "a different host is never offered the credential" {
    const saved = Origin{ .scheme = "https", .host = "bank.example" };
    const phish = Origin{ .scheme = "https", .host = "bank.example.evil" };
    try std.testing.expect(!mayOffer(saved, phish, true));
}

test "an insecure connection withholds the credential" {
    const saved = Origin{ .scheme = "https", .host = "bank.example" };
    const insecure = Origin{ .scheme = "http", .host = "bank.example" };
    try std.testing.expect(!mayOffer(saved, insecure, false));
}

test "autofill implies an exact secure origin match, swept" {
    // The phishing-resistance property: whenever a credential is offered, the origins matched
    // exactly and the connection was secure.
    const saved = Origin{ .scheme = "https", .host = "bank.example" };
    const pages = [_]Origin{
        .{ .scheme = "https", .host = "bank.example" },
        .{ .scheme = "http", .host = "bank.example" },
        .{ .scheme = "https", .host = "evil.example" },
        .{ .scheme = "https", .host = "bank.example.evil" },
    };
    for (pages) |page| {
        for ([_]bool{ false, true }) |secure| {
            if (mayOffer(saved, page, secure)) {
                try std.testing.expect(secure and saved.matches(page));
            }
        }
    }
}
