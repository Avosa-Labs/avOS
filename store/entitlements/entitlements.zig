//! Deciding whether an app may hold a powerful entitlement, so a capability with real reach is
//! granted only to an app whose stated purpose actually needs it.
//!
//! Entitlements are the special capabilities an app must be granted rather than simply request
//! at runtime — background location, reading all messages, health data, payment. They are
//! powerful enough that granting one to an app with no legitimate need is a standing risk: a
//! flashlight app with the contacts entitlement is a data grab waiting to happen. So an
//! entitlement is granted only when the app's declared category justifies it — a messaging app
//! may read messages, a navigation app may use background location, a wallet may take payments —
//! and an app requesting an entitlement outside what its category warrants is refused, because
//! the mismatch is exactly the signal of over-reach. The category is the app's own claim about
//! what it is, checked against a table of which entitlements each kind of app legitimately needs,
//! so entitlements track purpose rather than accumulating because an app asked.
//!
//! This module grants no entitlement. It decides whether an app's category justifies a requested
//! entitlement, against a fixed table, as a pure function.

const std = @import("std");

/// A powerful entitlement an app may request.
pub const Entitlement = enum {
    background_location,
    read_messages,
    health_data,
    take_payments,
    contacts,
};

/// The category an app declares itself to be.
pub const Category = enum {
    navigation,
    messaging,
    health,
    finance,
    utility,
};

/// Which entitlements each category legitimately needs. An entitlement not listed for a
/// category is not justified by it.
fn justifies(category: Category, entitlement: Entitlement) bool {
    return switch (category) {
        .navigation => entitlement == .background_location,
        .messaging => entitlement == .read_messages or entitlement == .contacts,
        .health => entitlement == .health_data,
        .finance => entitlement == .take_payments,
        .utility => false, // a utility justifies no powerful entitlement
    };
}

/// Whether an app of a category may be granted an entitlement.
///
/// The grant is allowed only when the app's declared category justifies the entitlement per the
/// table. An entitlement a category does not need is refused, because an app requesting reach
/// beyond its stated purpose is over-reaching. A utility category justifies no powerful
/// entitlement at all, which is the safe default for an app that has not claimed a purpose that
/// needs one.
pub fn mayGrant(category: Category, entitlement: Entitlement) bool {
    return justifies(category, entitlement);
}

test "a navigation app may hold background location" {
    try std.testing.expect(mayGrant(.navigation, .background_location));
}

test "a messaging app may read messages and contacts" {
    try std.testing.expect(mayGrant(.messaging, .read_messages));
    try std.testing.expect(mayGrant(.messaging, .contacts));
}

test "a finance app may take payments" {
    try std.testing.expect(mayGrant(.finance, .take_payments));
}

test "an app is refused an entitlement outside its category" {
    // A navigation app has no business reading messages.
    try std.testing.expect(!mayGrant(.navigation, .read_messages));
    // A messaging app does not get payments.
    try std.testing.expect(!mayGrant(.messaging, .take_payments));
}

test "a utility justifies no powerful entitlement" {
    for (std.enums.values(Entitlement)) |entitlement| {
        try std.testing.expect(!mayGrant(.utility, entitlement));
    }
}

test "every granted entitlement is justified by the category, swept" {
    // The purpose-tracking property: whenever an entitlement is granted, the category justifies
    // it.
    for (std.enums.values(Category)) |category| {
        for (std.enums.values(Entitlement)) |entitlement| {
            if (mayGrant(category, entitlement)) {
                try std.testing.expect(justifies(category, entitlement));
            }
        }
    }
}
