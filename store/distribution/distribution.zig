//! Deciding whether an app may be offered to a given device, so a person is shown only apps that
//! are available where they are and will run on what they hold.
//!
//! An approved app is not installable everywhere. It is offered in the regions the developer
//! chose and where it is legally permitted, and it runs only on devices that meet its
//! requirements — a minimum OS version, a hardware feature it depends on. Offering an app outside
//! these bounds wastes a person's time in the best case and fails at install in the worst: an app
//! not available in their country cannot be bought, and one needing a sensor their device lacks
//! cannot run. And an app the developer has withdrawn, or the store has removed, is offered
//! nowhere, because a pulled app should vanish from the storefront rather than linger as an
//! install that will not complete. So distribution checks region availability, device
//! compatibility, and withdrawal status, and offers an app only when all three permit, which
//! keeps the storefront showing a person exactly what they can actually get and use.
//!
//! This module distributes nothing. It decides whether an app is offerable to a device, from
//! region, compatibility, and status, as a pure function.

const std = @import("std");

/// An app's distribution attributes against a target.
pub const Offer = struct {
    /// Whether the app is available in the device's region.
    available_in_region: bool,
    /// Whether the device meets the app's minimum requirements.
    device_compatible: bool,
    /// Whether the app has been withdrawn by the developer or removed by the store.
    withdrawn: bool,
};

/// Why an app was not offered.
pub const Refusal = enum {
    /// The app is not available in the device's region.
    region_unavailable,
    /// The device does not meet the app's requirements.
    incompatible,
    /// The app has been withdrawn or removed.
    withdrawn,
};

/// The distribution decision.
pub const Decision = union(enum) {
    offer,
    refuse: Refusal,

    pub fn offered(decision: Decision) bool {
        return decision == .offer;
    }
};

/// Decides whether an app may be offered to a device.
///
/// A withdrawn app is offered nowhere, so a pulled app vanishes from the storefront. Otherwise
/// the app must be available in the device's region and compatible with the device. All three
/// conditions must hold; an app failing any is not offered, so the storefront shows only what a
/// person can actually obtain and run.
pub fn decide(offer: Offer) Decision {
    if (offer.withdrawn) return .{ .refuse = .withdrawn };
    if (!offer.available_in_region) return .{ .refuse = .region_unavailable };
    if (!offer.device_compatible) return .{ .refuse = .incompatible };
    return .offer;
}

fn makeOffer(region: bool, compatible: bool, withdrawn: bool) Offer {
    return .{ .available_in_region = region, .device_compatible = compatible, .withdrawn = withdrawn };
}

test "an available, compatible, current app is offered" {
    try std.testing.expect(decide(makeOffer(true, true, false)).offered());
}

test "a withdrawn app is offered nowhere" {
    try std.testing.expectEqual(Decision{ .refuse = .withdrawn }, decide(makeOffer(true, true, true)));
}

test "an app unavailable in the region is not offered" {
    try std.testing.expectEqual(Decision{ .refuse = .region_unavailable }, decide(makeOffer(false, true, false)));
}

test "an incompatible device is not offered the app" {
    try std.testing.expectEqual(Decision{ .refuse = .incompatible }, decide(makeOffer(true, false, false)));
}

test "no app is ever offered outside its bounds, swept" {
    // The correct-storefront property: an offered app is available in region, compatible, and not
    // withdrawn.
    for ([_]bool{ false, true }) |region| {
        for ([_]bool{ false, true }) |compatible| {
            for ([_]bool{ false, true }) |withdrawn| {
                if (decide(makeOffer(region, compatible, withdrawn)).offered()) {
                    try std.testing.expect(region and compatible and !withdrawn);
                }
            }
        }
    }
}
