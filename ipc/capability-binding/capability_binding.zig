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
    /// The generation the capability was minted at. A message presenting an older
    /// generation is presenting a handle from before a revocation.
    generation: u64 = 0,
    /// When the capability stops being valid, in nanoseconds on the shared clock,
    /// or null for no expiry.
    expires_at_ns: ?u64 = null,
    /// Set once the capability is revoked. Checked at every use, because the gap
    /// between issue and use is where a revoked handle would otherwise be honored.
    revoked: bool = false,
    /// The task the capability is bound to, or null for any. A message from
    /// another task may not present it.
    task_binding: ?u128 = null,
    /// Uses remaining, or null for unlimited. Zero is exhausted.
    invocations_remaining: ?u32 = null,

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
    /// The generation the envelope presents for the capability.
    generation: u64 = 0,
    /// The task the envelope claims to run under.
    task: u128 = 0,
    /// The current time in nanoseconds on the shared clock, for expiry.
    now_ns: u64 = 0,
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
    /// The presented generation predates a revocation of the capability.
    stale_generation,
    /// The capability has been revoked.
    revoked,
    /// The capability is past its expiry.
    expired,
    /// The capability is bound to a task other than the one the message claims.
    task_binding_violated,
    /// The capability's uses are spent.
    invocations_exhausted,
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

    // Revalidate the capability's own state at use, not just its shape: a handle
    // valid when it was minted may have been revoked, expired, spent, or bound to
    // a task other than the one now presenting it.
    if (grant.revoked) return .{ .refuse = .revoked };
    if (invocation.generation != grant.generation) return .{ .refuse = .stale_generation };
    if (grant.expires_at_ns) |expiry| {
        if (invocation.now_ns >= expiry) return .{ .refuse = .expired };
    }
    if (grant.task_binding) |bound_task| {
        if (invocation.task != bound_task) return .{ .refuse = .task_binding_violated };
    }
    if (grant.invocations_remaining) |remaining| {
        if (remaining == 0) return .{ .refuse = .invocations_exhausted };
    }

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

test "a revoked or stale-generation capability is refused at use" {
    var grant = calendar_grant;
    grant.generation = 3;
    // The message presents the current generation and is authorized.
    try std.testing.expect(check(grant, .{ .principal = holder, .method = "calendar.read", .generation = 3 }).authorized());
    // A message presenting an older generation is a pre-revocation handle.
    try std.testing.expectEqual(Refusal.stale_generation, check(grant, .{ .principal = holder, .method = "calendar.read", .generation = 2 }).refuse);

    grant.revoked = true;
    try std.testing.expectEqual(Refusal.revoked, check(grant, .{ .principal = holder, .method = "calendar.read", .generation = 3 }).refuse);
}

test "an expired capability is refused at its expiry" {
    var grant = calendar_grant;
    grant.expires_at_ns = 1_000;
    try std.testing.expect(check(grant, .{ .principal = holder, .method = "calendar.read", .now_ns = 999 }).authorized());
    try std.testing.expectEqual(Refusal.expired, check(grant, .{ .principal = holder, .method = "calendar.read", .now_ns = 1_000 }).refuse);
}

test "a task-bound capability refuses a message from another task" {
    var grant = calendar_grant;
    grant.task_binding = 0x7;
    try std.testing.expect(check(grant, .{ .principal = holder, .method = "calendar.read", .task = 0x7 }).authorized());
    try std.testing.expectEqual(Refusal.task_binding_violated, check(grant, .{ .principal = holder, .method = "calendar.read", .task = 0x9 }).refuse);
}

test "a spent capability is refused" {
    var grant = calendar_grant;
    grant.invocations_remaining = 0;
    try std.testing.expectEqual(Refusal.invocations_exhausted, check(grant, .{ .principal = holder, .method = "calendar.read" }).refuse);
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

test "checking a capability leaves it unchanged, so a replayed invocation decides the same" {
    // The check is a pure decision over the grant, not a spend: it never mutates the
    // grant, so presenting the same invocation twice — a duplicate or a replay —
    // always reaches the same verdict. A single-use capability is spent by the store
    // that owns it, not by asking whether it authorizes; the two must not be
    // conflated, or a replay would read as a second, distinct use.
    var grant = calendar_grant;
    grant.invocations_remaining = 1;
    const invocation = invoke(holder, "calendar.read");

    const first = check(grant, invocation);
    const second = check(grant, invocation);
    const third = check(grant, invocation);
    try std.testing.expect(first.authorized());
    try std.testing.expect(second.authorized());
    try std.testing.expect(third.authorized());
    // The grant itself is untouched by having been checked.
    try std.testing.expectEqual(@as(?u32, 1), grant.invocations_remaining);
}

test "when several conditions fail at once the refusal precedence is fixed" {
    // A grant can be defective in more than one way. The order the reasons are
    // reported is a contract: a caller keys retries and audit off the reason, so a
    // reorder that started reporting a different one for the same grant is a
    // behavior change, caught here. The order is: method shape, then principal, then
    // revoked, generation, expiry, task binding, invocations, and finally scope.
    const base: Grant = .{
        .bound_principal = holder,
        .generation = 5,
        .revoked = true,
        .expires_at_ns = 1_000,
        .task_binding = 0x7,
        .invocations_remaining = 0,
        .scopes = &.{.{ .pattern = "calendar.", .prefix = true }},
    };
    const past_expiry: u64 = 2_000;

    // Principal outranks every capability-state reason, even all of them together.
    const wrong_principal: Invocation = .{
        .principal = other,
        .method = "unscoped.method",
        .generation = 99,
        .task = 0x9,
        .now_ns = past_expiry,
    };
    try std.testing.expectEqual(Refusal.principal_mismatch, check(base, wrong_principal).refuse);

    // For the right principal, revoked is reported before generation, expiry, task,
    // invocations, or scope — all of which also fail here.
    const right_principal: Invocation = .{
        .principal = holder,
        .method = "unscoped.method",
        .generation = 99,
        .task = 0x9,
        .now_ns = past_expiry,
    };
    try std.testing.expectEqual(Refusal.revoked, check(base, right_principal).refuse);

    // Clear revoked and generation, and expiry is reported before task, invocations,
    // and scope.
    var not_revoked = base;
    not_revoked.revoked = false;
    const matched_generation: Invocation = .{
        .principal = holder,
        .method = "unscoped.method",
        .generation = 5,
        .task = 0x9,
        .now_ns = past_expiry,
    };
    try std.testing.expectEqual(Refusal.expired, check(not_revoked, matched_generation).refuse);

    // Within the deadline, the task binding is reported before invocations and scope.
    const within_deadline: Invocation = .{
        .principal = holder,
        .method = "unscoped.method",
        .generation = 5,
        .task = 0x9,
        .now_ns = 999,
    };
    try std.testing.expectEqual(Refusal.task_binding_violated, check(not_revoked, within_deadline).refuse);

    // Matching the task, the spent count is reported before scope.
    const matched_task: Invocation = .{
        .principal = holder,
        .method = "unscoped.method",
        .generation = 5,
        .task = 0x7,
        .now_ns = 999,
    };
    try std.testing.expectEqual(Refusal.invocations_exhausted, check(not_revoked, matched_task).refuse);

    // With every state reason satisfied, scope is the last line: an uncovered method
    // is out of scope.
    var spendable = not_revoked;
    spendable.invocations_remaining = 1;
    try std.testing.expectEqual(Refusal.out_of_scope, check(spendable, matched_task).refuse);
}
