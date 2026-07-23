//! Deciding whether a request may reach a resource given which account is active,
//! so data from one account can never be read while another is in use.
//!
//! A device may hold more than one account — a personal and a work profile, two
//! people sharing a tablet — and the whole point of the separation is that the
//! accounts do not see each other's data. That guarantee is only as good as the
//! check that enforces it: every resource belongs to exactly one account, and a
//! request made while an account is active may reach only that account's resources
//! and the ones deliberately shared with everyone. A resource owned by another
//! account is not merely hidden from the launcher; it is unreadable, because hiding
//! without enforcing is how a path or an id from one profile quietly pulls back the
//! other's data. Switching accounts is likewise a real boundary: until the switch
//! completes, the arriving account must not be treated as active, so a request in
//! flight during a switch cannot land in the wrong profile.
//!
//! This module owns no data. It decides whether a resource is reachable from the
//! active account, as a pure function over the two ownerships, so the isolation is
//! enforced at one gate rather than trusted to each service.

const std = @import("std");

/// An account identifier. Zero is reserved for "shared", data visible to every
/// account (system resources, a shared media library the person opted into).
pub const AccountId = u32;

/// The reserved id for resources shared across all accounts.
pub const shared: AccountId = 0;

/// Which account a resource belongs to.
pub const Ownership = struct {
    account: AccountId,

    fn isShared(ownership: Ownership) bool {
        return ownership.account == shared;
    }
};

/// Why a resource was not reachable.
pub const Refusal = enum {
    /// The resource belongs to a different account than the active one. The core
    /// isolation refusal.
    cross_account,
    /// No account is active — the session is between accounts, mid-switch — so
    /// nothing but shared data is reachable.
    no_active_account,
};

/// The outcome of a reachability check.
pub const Decision = union(enum) {
    reach,
    refuse: Refusal,

    pub fn reachable(decision: Decision) bool {
        return decision == .reach;
    }
};

/// The active-account context a request is made in.
pub const Context = struct {
    /// The account currently active, or `shared` (zero) meaning none is active —
    /// the session is mid-switch and only shared data is reachable.
    active: AccountId,

    fn hasActiveAccount(context: Context) bool {
        return context.active != shared;
    }
};

/// Decides whether a resource is reachable from the active account.
///
/// A shared resource is reachable from any context, because it belongs to no single
/// account. Otherwise an account must be active, and the resource must belong to it;
/// a resource owned by a different account is refused as cross-account, and a
/// request made while no account is active reaches nothing but shared data. The
/// check is ownership equality, not visibility, so a resource is unreadable across
/// the boundary rather than merely hidden.
pub fn reach(context: Context, ownership: Ownership) Decision {
    if (ownership.isShared()) return .reach;
    if (!context.hasActiveAccount()) return .{ .refuse = .no_active_account };
    if (ownership.account != context.active) return .{ .refuse = .cross_account };
    return .reach;
}

const personal: AccountId = 1;
const work: AccountId = 2;

fn makeContext(active: AccountId) Context {
    return .{ .active = active };
}

fn owned(account: AccountId) Ownership {
    return .{ .account = account };
}

test "a resource of the active account is reachable" {
    try std.testing.expect(reach(makeContext(personal), owned(personal)).reachable());
}

test "a resource of another account is refused as cross-account" {
    try std.testing.expectEqual(
        Decision{ .refuse = .cross_account },
        reach(makeContext(personal), owned(work)),
    );
}

test "a shared resource is reachable from any account" {
    try std.testing.expect(reach(makeContext(personal), owned(shared)).reachable());
    try std.testing.expect(reach(makeContext(work), owned(shared)).reachable());
}

test "a shared resource is reachable even with no active account" {
    try std.testing.expect(reach(makeContext(shared), owned(shared)).reachable());
}

test "no account active reaches nothing but shared" {
    // Mid-switch: an account resource is unreachable until the switch completes.
    try std.testing.expectEqual(
        Decision{ .refuse = .no_active_account },
        reach(makeContext(shared), owned(personal)),
    );
}

test "no cross-account read is ever reachable, swept" {
    // The isolation property: for every pair of accounts, a resource is reachable
    // only when it is shared or its owner is the active account.
    const accounts = [_]AccountId{ personal, work, 3 };
    for (accounts) |active| {
        for (accounts) |owner| {
            const decision = reach(makeContext(active), owned(owner));
            if (decision.reachable()) {
                try std.testing.expectEqual(active, owner); // only same-account reached
            }
        }
        // Shared is always reachable.
        try std.testing.expect(reach(makeContext(active), owned(shared)).reachable());
    }
}
