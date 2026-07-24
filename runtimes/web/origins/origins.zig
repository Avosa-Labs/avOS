//! Deciding whether one web origin may reach another's state, so a page the person
//! opened cannot read the data of a site they are logged into.
//!
//! The web's security rests on the same-origin policy: content from one origin — the
//! scheme, host, and port a page came from — may not read the state of another. It is
//! the rule that stops a page on one site from reading your bank's cookies or scripting
//! its DOM, and a web runtime that hosts real sites has to enforce it exactly, because
//! relaxing it by a hair is how cross-site data theft happens. Two contexts share an
//! origin only when scheme, host, and port all match; differ in any one and they are
//! separate origins that cannot touch each other's state. The one deliberate opening is
//! an explicit cross-origin grant — a site that opts in to sharing with a named other
//! origin — which is a decision the target site makes, never one the requesting page
//! can take for itself.
//!
//! This module renders no page. It decides whether one origin may access another's
//! state, comparing scheme, host, and port and honouring only explicit opt-in, as a
//! pure function over the two origins.

const std = @import("std");

/// A web origin: the triple that identifies a security context.
pub const Origin = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,

    /// Whether two origins are the same: scheme, host, and port all equal. A
    /// difference in any one makes them separate origins.
    pub fn sameAs(origin: Origin, other: Origin) bool {
        return std.mem.eql(u8, origin.scheme, other.scheme) and
            std.mem.eql(u8, origin.host, other.host) and
            origin.port == other.port;
    }
};

/// An explicit cross-origin grant: a target origin opting in to being accessed by a
/// specific requesting origin. The grant belongs to the target, never the requester.
pub const CrossOriginGrant = struct {
    /// The origin whose state may be accessed.
    target: Origin,
    /// The origin permitted to access it.
    allowed: Origin,
};

/// Whether a requesting origin may access a target origin's state, given any explicit
/// grants the target has published.
///
/// Same-origin access is always allowed — a context may reach its own state. Otherwise
/// the requester may access the target only if the target published a grant naming that
/// exact requester; a page cannot grant itself access to another origin. Absent a
/// matching grant, cross-origin access is denied, which is the default the whole policy
/// depends on.
pub fn mayAccess(requester: Origin, target: Origin, grants: []const CrossOriginGrant) bool {
    if (requester.sameAs(target)) return true;
    for (grants) |grant| {
        if (grant.target.sameAs(target) and grant.allowed.sameAs(requester)) return true;
    }
    return false;
}

const app: Origin = .{ .scheme = "https", .host = "app.example", .port = 443 };
const bank: Origin = .{ .scheme = "https", .host = "bank.example", .port = 443 };
const app_http: Origin = .{ .scheme = "http", .host = "app.example", .port = 80 };

test "an origin may access its own state" {
    try std.testing.expect(mayAccess(app, app, &.{}));
}

test "a different host is a different origin and is denied" {
    try std.testing.expect(!mayAccess(app, bank, &.{}));
}

test "a different scheme is a different origin" {
    // https and http of the same host are separate origins.
    try std.testing.expect(!app.sameAs(app_http));
    try std.testing.expect(!mayAccess(app, app_http, &.{}));
}

test "a different port is a different origin" {
    const app_8443: Origin = .{ .scheme = "https", .host = "app.example", .port = 8443 };
    try std.testing.expect(!app.sameAs(app_8443));
}

test "an explicit grant from the target permits a named requester" {
    const grants = [_]CrossOriginGrant{.{ .target = bank, .allowed = app }};
    try std.testing.expect(mayAccess(app, bank, &grants));
}

test "a grant only permits the exact requester it names" {
    const other: Origin = .{ .scheme = "https", .host = "evil.example", .port = 443 };
    const grants = [_]CrossOriginGrant{.{ .target = bank, .allowed = app }};
    // The grant is for app, not other.
    try std.testing.expect(!mayAccess(other, bank, &grants));
}

test "a page cannot grant itself access to another origin" {
    // A grant whose target is not the origin being accessed does not apply. Here a
    // grant on `app` does not let `app` reach `bank`.
    const self_grant = [_]CrossOriginGrant{.{ .target = app, .allowed = app }};
    try std.testing.expect(!mayAccess(app, bank, &self_grant));
}

test "cross-origin access is denied without a matching grant, swept" {
    // The same-origin property: for distinct origins, access is allowed only via an
    // explicit target grant naming the requester.
    const origins = [_]Origin{ app, bank, app_http };
    for (origins) |requester| {
        for (origins) |target| {
            const allowed = mayAccess(requester, target, &.{});
            if (allowed) try std.testing.expect(requester.sameAs(target));
        }
    }
}
