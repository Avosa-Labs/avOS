//! Deciding whether an HTTP request may be retried and whether a redirect may be
//! followed, so an automatic client cannot double a side effect or be steered
//! somewhere it should not go.
//!
//! Two HTTP mechanisms are automatic — retries and redirects — and both are only
//! safe under a policy the individual client should not be trusted to reinvent.
//! An automatic retry is safe for a request that has no side effect or the same
//! effect however many times it runs, and dangerous for one that does not: a
//! retried payment can charge twice. An automatic redirect hands control of the
//! destination to the server, which is how a request meant for one origin ends up
//! carrying the person's credentials to another, or aimed from a public name at
//! an address inside the device — the same rebinding shape the resolver guards,
//! arriving this time through a Location header. So both decisions live here, once,
//! rather than in every client that speaks HTTP.
//!
//! This module sends no request and follows no redirect. It answers whether a
//! method may be safely retried and whether a specific redirect may be followed,
//! as pure functions over the method, the hop count, and how the origin and
//! credential-carrying change across the hop.

const std = @import("std");

/// An HTTP request method, classified by what it does to the server so retry and
/// caching decisions can be made without knowing the specific request.
pub const Method = enum {
    get,
    head,
    options,
    post,
    put,
    delete,
    patch,

    /// Whether the method is safe: defined to have no side effect on the server,
    /// so issuing it — or reissuing it — changes nothing.
    pub fn isSafe(method: Method) bool {
        return switch (method) {
            .get, .head, .options => true,
            .post, .put, .delete, .patch => false,
        };
    }

    /// Whether the method is idempotent: issuing it twice leaves the server in the
    /// same state as issuing it once. Safe methods are idempotent, and so are PUT
    /// and DELETE by definition; POST and PATCH are not.
    pub fn isIdempotent(method: Method) bool {
        return switch (method) {
            .get, .head, .options, .put, .delete => true,
            .post, .patch => false,
        };
    }
};

/// Whether an automatic retry of a request is permitted.
///
/// A request may be retried automatically only if the method is idempotent, so
/// that a retry after an ambiguous failure — a timeout where the request may or
/// may not have been applied — cannot apply it a second time. A non-idempotent
/// request that failed ambiguously must be left to a person or higher layer that
/// knows whether repeating it is safe, never retried blindly by the transport.
pub fn mayRetry(method: Method) bool {
    return method.isIdempotent();
}

/// The most redirects that may be followed for one request before it is treated
/// as a loop. Enough for legitimate chains, short enough that a redirect cycle
/// terminates quickly.
pub const max_redirect_hops: u8 = 5;

/// One redirect hop: what changes between the request's current location and the
/// Location it is being pointed to.
pub const Redirect = struct {
    /// Which hop this is, counting from 1 for the first redirect. Used against the
    /// hop ceiling.
    hop: u8,
    /// Whether the redirect crosses to a different origin (scheme, host, or port
    /// changes).
    cross_origin: bool,
    /// Whether the request carries credentials — a cookie, an authorization
    /// header, a bearer token — that would travel to the new location.
    carries_credentials: bool,
    /// Whether the target resolves to an address inside the trust boundary: the
    /// device itself or its local network. Rebinding through a Location header.
    target_is_internal: bool,
    /// Whether the redirect downgrades the transport from a secure scheme to an
    /// insecure one (https to http).
    downgrades_transport: bool,
};

/// Why a redirect was refused.
pub const RedirectRefusal = enum {
    /// The hop ceiling was reached: the chain is treated as a loop and stopped.
    too_many_hops,
    /// The redirect would carry the person's credentials to a different origin,
    /// leaking them to a server that was never granted them.
    credential_leak,
    /// The redirect points inside the trust boundary from outside it: the
    /// rebinding case, arriving through a Location header.
    internal_target,
    /// The redirect would drop from a secure transport to an insecure one,
    /// exposing a request that began protected.
    transport_downgrade,
};

/// The outcome of a redirect decision.
pub const RedirectDecision = union(enum) {
    follow,
    refuse: RedirectRefusal,

    pub fn followed(decision: RedirectDecision) bool {
        return decision == .follow;
    }
};

/// Decides whether a redirect may be followed.
///
/// The chain is bounded first: past the hop ceiling it is a loop and is stopped.
/// A cross-origin redirect that would carry credentials is refused, because the
/// credentials were granted to the original origin and following would hand them
/// to another. A redirect into the trust boundary from outside is refused as the
/// Location-header form of rebinding. A transport downgrade is refused, because a
/// request that began secure must not be silently exposed. Only a redirect that
/// trips none of these is followed.
pub fn mayFollowRedirect(redirect: Redirect) RedirectDecision {
    if (redirect.hop > max_redirect_hops) return .{ .refuse = .too_many_hops };
    if (redirect.cross_origin and redirect.carries_credentials) {
        return .{ .refuse = .credential_leak };
    }
    if (redirect.target_is_internal) return .{ .refuse = .internal_target };
    if (redirect.downgrades_transport) return .{ .refuse = .transport_downgrade };
    return .follow;
}

fn safeRedirect(hop: u8) Redirect {
    return .{
        .hop = hop,
        .cross_origin = false,
        .carries_credentials = false,
        .target_is_internal = false,
        .downgrades_transport = false,
    };
}

test "safe methods are the read-only ones" {
    try std.testing.expect(Method.get.isSafe());
    try std.testing.expect(Method.head.isSafe());
    try std.testing.expect(Method.options.isSafe());
    try std.testing.expect(!Method.post.isSafe());
    try std.testing.expect(!Method.put.isSafe());
    try std.testing.expect(!Method.delete.isSafe());
    try std.testing.expect(!Method.patch.isSafe());
}

test "idempotent methods include PUT and DELETE but not POST or PATCH" {
    try std.testing.expect(Method.put.isIdempotent());
    try std.testing.expect(Method.delete.isIdempotent());
    try std.testing.expect(!Method.post.isIdempotent());
    try std.testing.expect(!Method.patch.isIdempotent());
}

test "only idempotent requests may be retried automatically" {
    // A retried POST could double a payment; a retried PUT lands the same state.
    try std.testing.expect(mayRetry(.get));
    try std.testing.expect(mayRetry(.put));
    try std.testing.expect(mayRetry(.delete));
    try std.testing.expect(!mayRetry(.post));
    try std.testing.expect(!mayRetry(.patch));
}

test "every safe method is retryable" {
    // Safety implies idempotence implies retryable; the classification must not
    // contradict itself.
    for (std.enums.values(Method)) |method| {
        if (method.isSafe()) try std.testing.expect(mayRetry(method));
    }
}

test "an ordinary same-origin redirect is followed" {
    try std.testing.expect(mayFollowRedirect(safeRedirect(1)).followed());
}

test "a redirect past the hop ceiling is refused as a loop" {
    try std.testing.expectEqual(
        RedirectDecision{ .refuse = .too_many_hops },
        mayFollowRedirect(safeRedirect(max_redirect_hops + 1)),
    );
    // The last permitted hop still follows.
    try std.testing.expect(mayFollowRedirect(safeRedirect(max_redirect_hops)).followed());
}

test "a cross-origin redirect carrying credentials is refused" {
    var redirect = safeRedirect(1);
    redirect.cross_origin = true;
    redirect.carries_credentials = true;
    try std.testing.expectEqual(
        RedirectDecision{ .refuse = .credential_leak },
        mayFollowRedirect(redirect),
    );
}

test "a cross-origin redirect without credentials is followed" {
    // Crossing origins is fine when nothing secret travels with the request.
    var redirect = safeRedirect(1);
    redirect.cross_origin = true;
    try std.testing.expect(mayFollowRedirect(redirect).followed());
}

test "a redirect into the trust boundary is refused as rebinding" {
    var redirect = safeRedirect(1);
    redirect.target_is_internal = true;
    try std.testing.expectEqual(
        RedirectDecision{ .refuse = .internal_target },
        mayFollowRedirect(redirect),
    );
}

test "a transport downgrade is refused" {
    var redirect = safeRedirect(1);
    redirect.downgrades_transport = true;
    try std.testing.expectEqual(
        RedirectDecision{ .refuse = .transport_downgrade },
        mayFollowRedirect(redirect),
    );
}

test "the hop ceiling is checked before the other refusals" {
    // A redirect that is both over the ceiling and otherwise unsafe reports the
    // loop, so a redirect cycle terminates rather than reporting a rotating cause.
    var redirect = safeRedirect(max_redirect_hops + 1);
    redirect.target_is_internal = true;
    redirect.downgrades_transport = true;
    try std.testing.expectEqual(
        RedirectDecision{ .refuse = .too_many_hops },
        mayFollowRedirect(redirect),
    );
}

test "no credential ever crosses an origin through a redirect, swept" {
    // The property: for every hop within the ceiling, a followed redirect that
    // crosses origins never carried credentials.
    var hop: u8 = 1;
    while (hop <= max_redirect_hops) : (hop += 1) {
        for ([_]bool{ false, true }) |cross| {
            for ([_]bool{ false, true }) |creds| {
                var redirect = safeRedirect(hop);
                redirect.cross_origin = cross;
                redirect.carries_credentials = creds;
                if (mayFollowRedirect(redirect).followed() and cross) {
                    try std.testing.expect(!creds);
                }
            }
        }
    }
}
