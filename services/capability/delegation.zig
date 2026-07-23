//! Deciding whether a capability may be re-delegated, allowing only attenuation and
//! bounding the chain, so passing authority on can narrow it but never widen it.
//!
//! A capability is authority a holder can pass to another — an agent hands a
//! sub-agent the right to read one folder so it can do part of a job. Delegation is
//! what makes that composable, and it is safe only under two rules. It attenuates:
//! the delegated capability may cover less than the holder's but never more, because
//! delegation that could add scope would let any holder manufacture authority it was
//! never given. And the chain is bounded: a capability may be re-delegated only so
//! many times before it may no longer be passed on, because an unbounded chain is an
//! unbounded blast radius — authority that spreads through arbitrarily many hands is
//! authority no one can reason about or revoke cleanly. A capability marked
//! non-delegatable stops at its holder entirely. Together these keep delegated
//! authority a strict subset of the original, held by a bounded, known set of hands.
//!
//! This module delegates nothing. It decides whether a proposed delegation is
//! permitted, checking delegability, attenuation, and depth, as a pure function over
//! the parent capability and the requested child.

const std = @import("std");

/// The scope of a capability: which operations it covers. A subset relationship is
/// what "attenuation" is checked against.
pub const Scope = std.EnumSet(Operation);

/// An operation a capability may authorize. Small and illustrative; the delegation
/// rule is the same whatever the operation set.
pub const Operation = enum { read, write, delete, share };

/// A capability that may be delegated.
pub const Capability = struct {
    scope: Scope,
    /// Whether this capability may be delegated at all.
    delegatable: bool,
    /// How many further delegations remain permitted from here. Zero means this
    /// capability may not be delegated again even if delegatable.
    remaining_depth: u8,
};

/// Why a delegation was refused.
pub const Refusal = enum {
    /// The parent capability is not delegatable.
    not_delegatable,
    /// The delegation chain has reached its depth bound.
    depth_exhausted,
    /// The child would cover an operation the parent does not: a widening.
    widens_scope,
};

/// The delegation decision.
pub const Decision = union(enum) {
    /// The delegation is permitted; the child is issued with this remaining depth.
    delegate: u8,
    refuse: Refusal,

    pub fn permitted(decision: Decision) bool {
        return decision == .delegate;
    }
};

/// Decides whether `parent` may be delegated as a capability with `child_scope`.
///
/// The parent must be delegatable and have depth remaining, or the chain stops here.
/// The child's scope must be a subset of the parent's — every operation it covers,
/// the parent covers too — so the delegation attenuates and never widens. A permitted
/// delegation issues a child whose remaining depth is one less than the parent's, so
/// the chain shortens with every hop and cannot run forever.
pub fn decide(parent: Capability, child_scope: Scope) Decision {
    if (!parent.delegatable) return .{ .refuse = .not_delegatable };
    if (parent.remaining_depth == 0) return .{ .refuse = .depth_exhausted };
    // Attenuation: the child's scope must be a subset of the parent's — every
    // operation the child covers, the parent covers too. Anything else widens.
    if (!child_scope.subsetOf(parent.scope)) return .{ .refuse = .widens_scope };
    return .{ .delegate = parent.remaining_depth - 1 };
}

fn scopeOf(operations: []const Operation) Scope {
    var scope: Scope = .initEmpty();
    for (operations) |operation| scope.insert(operation);
    return scope;
}

test "a delegatable capability attenuates to a subset" {
    const parent: Capability = .{ .scope = scopeOf(&.{ .read, .write }), .delegatable = true, .remaining_depth = 3 };
    // Delegate read only: a strict subset.
    const decision = decide(parent, scopeOf(&.{.read}));
    try std.testing.expect(decision.permitted());
}

test "delegation decrements the remaining depth" {
    const parent: Capability = .{ .scope = scopeOf(&.{.read}), .delegatable = true, .remaining_depth = 3 };
    switch (decide(parent, scopeOf(&.{.read}))) {
        .delegate => |depth| try std.testing.expectEqual(@as(u8, 2), depth),
        .refuse => return error.TestUnexpectedResult,
    }
}

test "a non-delegatable capability stops at its holder" {
    const parent: Capability = .{ .scope = scopeOf(&.{.read}), .delegatable = false, .remaining_depth = 3 };
    try std.testing.expectEqual(Decision{ .refuse = .not_delegatable }, decide(parent, scopeOf(&.{.read})));
}

test "an exhausted depth refuses further delegation" {
    const parent: Capability = .{ .scope = scopeOf(&.{.read}), .delegatable = true, .remaining_depth = 0 };
    try std.testing.expectEqual(Decision{ .refuse = .depth_exhausted }, decide(parent, scopeOf(&.{.read})));
}

test "a child that widens the scope is refused" {
    // Parent covers read; child asks for read and write. Write is not in the parent.
    const parent: Capability = .{ .scope = scopeOf(&.{.read}), .delegatable = true, .remaining_depth = 3 };
    try std.testing.expectEqual(Decision{ .refuse = .widens_scope }, decide(parent, scopeOf(&.{ .read, .write })));
}

test "an equal scope is permitted; it is a subset of itself" {
    const parent: Capability = .{ .scope = scopeOf(&.{ .read, .write }), .delegatable = true, .remaining_depth = 1 };
    try std.testing.expect(decide(parent, scopeOf(&.{ .read, .write })).permitted());
}

test "a chain shortens to zero and then stops, swept" {
    // Starting from depth N, each hop decrements; a capability issued at depth 0
    // cannot be delegated again.
    var depth: u8 = 3;
    const scope = scopeOf(&.{.read});
    while (depth > 0) : (depth -= 1) {
        const parent: Capability = .{ .scope = scope, .delegatable = true, .remaining_depth = depth };
        switch (decide(parent, scope)) {
            .delegate => |child_depth| try std.testing.expectEqual(depth - 1, child_depth),
            .refuse => return error.TestUnexpectedResult,
        }
    }
    const exhausted: Capability = .{ .scope = scope, .delegatable = true, .remaining_depth = 0 };
    try std.testing.expect(!decide(exhausted, scope).permitted());
}

test "no permitted delegation ever covers an operation the parent lacks, swept" {
    // The attenuation property: across a range of parent and child scopes, a
    // permitted child is always a subset of the parent.
    const all = [_][]const Operation{
        &.{.read}, &.{ .read, .write }, &.{ .read, .write, .delete }, &.{.share},
    };
    for (all) |parent_ops| {
        for (all) |child_ops| {
            const parent: Capability = .{ .scope = scopeOf(parent_ops), .delegatable = true, .remaining_depth = 2 };
            const child = scopeOf(child_ops);
            if (decide(parent, child).permitted()) {
                // Every child operation is in the parent.
                try std.testing.expect(child.subsetOf(parent.scope));
            }
        }
    }
}
