//! Deciding whether a purchase completes and whether a refund is allowed, so a person is charged
//! once for what they buy and can undo a mistaken purchase within a fair window.
//!
//! Commerce in a store has to be exact about money, because errors here are the ones people
//! remember. A purchase completes only when payment is authorized and the person does not already
//! own the item — charging twice for something already bought is the complaint that erodes trust
//! in a storefront, so an already-owned item is not re-charged but simply granted. And a refund is
//! allowed within a window after purchase, because a person who bought the wrong thing, or found
//! an app did not work, deserves to undo it — but only within a bounded time and only if they have
//! not consumed what a refund would take back, so the window is not a way to use something and
//! return it for free. Getting these two decisions right — one charge per purchase, refunds inside
//! a fair, bounded window — is what makes buying from the store feel safe rather than risky.
//!
//! This module moves no money. It decides whether a purchase completes and whether a refund is
//! allowed, as pure functions.

const std = @import("std");

/// A purchase attempt.
pub const Purchase = struct {
    /// Whether payment was authorized.
    payment_authorized: bool,
    /// Whether the person already owns the item.
    already_owned: bool,
};

/// The outcome of a purchase.
pub const PurchaseOutcome = enum {
    /// Charge and grant the item.
    charge_and_grant,
    /// The person already owns it; grant without charging again.
    grant_without_charge,
    /// Payment failed; nothing is granted.
    declined,

    pub fn grants(outcome: PurchaseOutcome) bool {
        return outcome == .charge_and_grant or outcome == .grant_without_charge;
    }
};

/// Decides the outcome of a purchase.
///
/// An already-owned item is granted without charging again, so no one pays twice for what they
/// have. Otherwise payment must be authorized to charge and grant; unauthorized payment is
/// declined and grants nothing. The already-owned check precedes the payment check, so a repeat
/// purchase is never charged even if payment would have authorized.
pub fn purchase(attempt: Purchase) PurchaseOutcome {
    if (attempt.already_owned) return .grant_without_charge;
    if (!attempt.payment_authorized) return .declined;
    return .charge_and_grant;
}

/// The refund window, in milliseconds, after purchase within which a refund may be requested.
pub const refund_window_ms: i64 = 14 * 24 * 60 * 60 * 1000; // 14 days

/// Whether a refund is allowed for a purchase.
///
/// A refund is allowed only within the window after purchase and only if the item has not been
/// consumed in a way a refund would unfairly take back. Past the window, or for a consumed item, a
/// refund is refused, so the window cannot be used to get free use and return.
pub fn refundAllowed(age_ms: i64, consumed: bool) bool {
    if (consumed) return false;
    return age_ms >= 0 and age_ms <= refund_window_ms;
}

test "an authorized new purchase charges and grants" {
    try std.testing.expectEqual(PurchaseOutcome.charge_and_grant, purchase(.{ .payment_authorized = true, .already_owned = false }));
}

test "an already-owned item grants without charging again" {
    try std.testing.expectEqual(PurchaseOutcome.grant_without_charge, purchase(.{ .payment_authorized = true, .already_owned = true }));
    // Even if payment would fail, an owned item is granted, not charged.
    try std.testing.expectEqual(PurchaseOutcome.grant_without_charge, purchase(.{ .payment_authorized = false, .already_owned = true }));
}

test "unauthorized payment for a new item is declined" {
    try std.testing.expectEqual(PurchaseOutcome.declined, purchase(.{ .payment_authorized = false, .already_owned = false }));
}

test "a refund is allowed within the window for an unconsumed item" {
    try std.testing.expect(refundAllowed(1000, false));
    try std.testing.expect(refundAllowed(refund_window_ms, false));
}

test "a refund past the window is refused" {
    try std.testing.expect(!refundAllowed(refund_window_ms + 1, false));
}

test "a consumed item is not refundable" {
    try std.testing.expect(!refundAllowed(1000, true));
}

test "no item is ever charged twice, swept" {
    // The one-charge property: an already-owned item is never the charge_and_grant outcome.
    for ([_]bool{ false, true }) |payment| {
        const outcome = purchase(.{ .payment_authorized = payment, .already_owned = true });
        try std.testing.expect(outcome != .charge_and_grant);
    }
}

test "no refund is ever allowed past the window or for a consumed item, swept" {
    var age: i64 = 0;
    while (age <= refund_window_ms * 2) : (age += refund_window_ms / 4) {
        for ([_]bool{ false, true }) |consumed| {
            if (refundAllowed(age, consumed)) {
                try std.testing.expect(!consumed and age <= refund_window_ms);
            }
        }
    }
}
