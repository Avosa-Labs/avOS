//! Deciding whether the capability a message presents actually covers the method
//! it invokes, and is held by the principal the message claims — the
//! confused-deputy check at the wire boundary.
//!
//! A message carries a method and a capability, and the authenticator proves the
//! message is genuine and fresh. What that does not prove is that the capability
//! authorizes this particular method: a service that verifies the signature and
//! then acts, trusting that whoever sent a valid message must be allowed to invoke
//! whatever method it named, is a confused deputy — it lends its own authority to
//! a caller who presented a capability for something narrower. A capability for
//! "calendar.read" must not carry a "wallet.pay". And a capability is bound to the
//! principal it was issued to, so a message that presents a capability while
//! claiming a different principal is presenting one it does not hold.
//!
//! This module invokes nothing. It answers whether a presented grant covers a
//! method and is bound to the claiming principal, matching the method against the
//! grant's scopes — exact names and namespace prefixes — as a pure decision that
//! runs at the boundary before any service logic sees the request.

const std = @import("std");

/// The largest method name matched. Kept in step with the envelope and router
/// bounds; a name longer than this is out of scope by construction.
pub const max_method_bytes: usize = 64;

/// One authorization a capability grants. A scope either names a method exactly,
/// or names a namespace it covers wholesale.
pub const Scope = struct {
    /// The pattern. When `prefix` is true this is a namespace like "calendar."
    /// covering every "calendar.*"; otherwise it is an exact method name.
    pattern: []const u8,
    /// Whether the pattern is a namespace prefix rather than an exact method.
    prefix: bool = false,

    /// Whether this scope covers a given method.
    ///
    /// A prefix scope covers a method that starts with the pattern and has more
    /// beyond it, so "calendar." covers "calendar.read" but not the bare
    /// "calendar" and not "calendaring.read". An exact scope covers only the
    /// identical method.
    pub fn covers(scope: Scope, method: []const u8) bool {
        if (scope.prefix) {
            return method.len > scope.pattern.len and
                std.mem.startsWith(u8, method, scope.pattern);
        }
        return std.mem.eql(u8, scope.pattern, method);
    }
};

/// A capability as presented in a message: what it authorizes and who holds it.
pub const Grant = struct {
    /// The principal this capability was issued to and is bound to. A message
    /// presenting it must claim this same principal.
    bound_principal: u128,
    /// The methods this capability authorizes.
    scopes: []const Scope,

    fn coversMethod(grant: Grant, method: []const u8) bool {
        for (grant.scopes) |scope| {
            if (scope.covers(method)) return true;
        }
        return false;
    }
};

/// What a message claims to be doing, from its envelope.
pub const Invocation = struct {
    /// The principal the envelope claims to act on behalf of.
    principal: u128,
    /// The method the envelope invokes.
    method: []const u8,
};

/// Why a binding was refused.
pub const Refusal = enum {
    /// The capability is bound to a different principal than the message claims:
    /// it is being presented by someone who does not hold it.
    principal_mismatch,
    /// The capability's scopes do not cover the invoked method: it authorizes
    /// something, but not this.
    out_of_scope,
    /// The method name is longer than the boundary will match; out of scope by
    /// construction.
    method_too_long,
};

/// The outcome of a binding check.
pub const Decision = union(enum) {
    authorize,
    refuse: Refusal,

    pub fn authorized(decision: Decision) bool {
        return decision == .authorize;
    }
};

/// Decides whether a presented grant authorizes an invocation.
///
/// The principal binding is checked first: a capability bound to one principal
/// presented by a message claiming another is refused before its scopes are even
/// consulted, because it is not the claimant's capability to present. Then the
/// method must fall within one of the grant's scopes; a method no scope covers is
/// refused, so a capability for one thing never authorizes another. An over-long
/// method is refused outright.
pub fn check(grant: Grant, invocation: Invocation) Decision {
    if (invocation.method.len > max_method_bytes) return .{ .refuse = .method_too_long };
    if (grant.bound_principal != invocation.principal) return .{ .refuse = .principal_mismatch };
    if (!grant.coversMethod(invocation.method)) return .{ .refuse = .out_of_scope };
    return .authorize;
}

const holder: u128 = 0xCAFE;
const other: u128 = 0xF00D;

const calendar_grant: Grant = .{
    .bound_principal = holder,
    .scopes = &.{
        .{ .pattern = "calendar.", .prefix = true },
        .{ .pattern = "contacts.read" },
    },
};

fn invoke(principal: u128, method: []const u8) Invocation {
    return .{ .principal = principal, .method = method };
}

test "a method within a prefix scope is authorized" {
    try std.testing.expect(check(calendar_grant, invoke(holder, "calendar.read")).authorized());
    try std.testing.expect(check(calendar_grant, invoke(holder, "calendar.write")).authorized());
}

test "a method within an exact scope is authorized" {
    try std.testing.expect(check(calendar_grant, invoke(holder, "contacts.read")).authorized());
}

test "a method no scope covers is refused as out of scope" {
    try std.testing.expectEqual(
        Decision{ .refuse = .out_of_scope },
        check(calendar_grant, invoke(holder, "wallet.pay")),
    );
    // A near miss on the exact scope is still out of scope.
    try std.testing.expectEqual(
        Decision{ .refuse = .out_of_scope },
        check(calendar_grant, invoke(holder, "contacts.write")),
    );
}

test "a prefix does not cover its bare namespace or a longer namesake" {
    // "calendar." covers "calendar.read" but not the bare "calendar" and not
    // "calendaring.read": the prefix must be followed by more within the same name.
    try std.testing.expectEqual(
        Decision{ .refuse = .out_of_scope },
        check(calendar_grant, invoke(holder, "calendar")),
    );
    try std.testing.expectEqual(
        Decision{ .refuse = .out_of_scope },
        check(calendar_grant, invoke(holder, "calendaring.read")),
    );
}

test "a capability presented by another principal is refused" {
    // The binding check: this capability is holder's, and a message claiming
    // `other` may not present it, even for a method it covers.
    try std.testing.expectEqual(
        Decision{ .refuse = .principal_mismatch },
        check(calendar_grant, invoke(other, "calendar.read")),
    );
}

test "the principal binding is checked before the scope" {
    // A message from the wrong principal invoking an out-of-scope method reports
    // the principal mismatch: it never had standing to present this capability.
    try std.testing.expectEqual(
        Decision{ .refuse = .principal_mismatch },
        check(calendar_grant, invoke(other, "wallet.pay")),
    );
}

test "an over-long method is refused" {
    const long: [max_method_bytes + 1]u8 = @splat('c');
    try std.testing.expectEqual(
        Decision{ .refuse = .method_too_long },
        check(calendar_grant, invoke(holder, &long)),
    );
}

test "a grant with no scopes authorizes nothing" {
    const empty: Grant = .{ .bound_principal = holder, .scopes = &.{} };
    try std.testing.expectEqual(
        Decision{ .refuse = .out_of_scope },
        check(empty, invoke(holder, "calendar.read")),
    );
}

test "a capability for one thing never authorizes another, swept" {
    // The confused-deputy property: for the correct holder, a method is authorized
    // exactly when some scope covers it, and never otherwise.
    const methods = [_][]const u8{
        "calendar.read",  "calendar.write", "contacts.read",
        "contacts.write", "wallet.pay",     "calendar",
    };
    for (methods) |method| {
        const decision = check(calendar_grant, invoke(holder, method));
        var covered = false;
        for (calendar_grant.scopes) |scope| {
            if (scope.covers(method)) covered = true;
        }
        try std.testing.expectEqual(covered, decision.authorized());
    }
}
