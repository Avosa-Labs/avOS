//! Bluetooth pairing and bonded-device trust.
//!
//! A radio that will connect to anything is a radio an attacker can be. Trust
//! here is earned by pairing and remembered by bonding: a device the user
//! authorized once is bonded and may reconnect, and a device that presents a
//! bonded device's address but cannot prove the bond is refused rather than
//! trusted on the name alone. This is the policy; a board carries the packets.

const std = @import("std");

/// A device address. Opaque here; the board knows what it means on the air.
pub const Address = u48;

pub const PairError = enum {
    /// The user did not authorize the pairing.
    not_authorized,
    /// The numeric comparison the user was shown did not match, so a
    /// man-in-the-middle may be relaying the pairing.
    comparison_mismatch,
    /// No room to remember another bonded device.
    bond_store_full,
};

pub const ConnectRefusal = enum {
    /// The address is not one this device has bonded with.
    not_bonded,
    /// The address is bonded, but the link key it presented does not match, so it
    /// is an impersonator, not the bonded device.
    key_mismatch,
};

pub const Bond = struct {
    address: Address,
    /// A per-bond secret established at pairing. A reconnecting device proves it
    /// holds the same one; presenting the address is not enough.
    link_key: u128,
};

pub const capacity: usize = 16;

/// The set of devices this radio trusts, and the pairing/connection policy.
pub const Radio = struct {
    bonds: [capacity]?Bond = @splat(null),

    /// Records a new bond after the user authorized the pairing and the numeric
    /// comparison matched. Refuses if either was not satisfied, or if there is no
    /// room to remember it.
    pub fn pair(
        radio: *Radio,
        address: Address,
        link_key: u128,
        user_authorized: bool,
        comparison_matched: bool,
    ) ?PairError {
        if (!user_authorized) return .not_authorized;
        if (!comparison_matched) return .comparison_mismatch;
        for (&radio.bonds) |*slot| {
            if (slot.* == null or slot.*.?.address == address) {
                slot.* = .{ .address = address, .link_key = link_key };
                return null;
            }
        }
        return .bond_store_full;
    }

    /// Whether a reconnecting device may connect: it must be bonded and prove it
    /// holds the bond's link key. An address alone, or a wrong key, is refused.
    pub fn connect(radio: Radio, address: Address, presented_key: u128) ?ConnectRefusal {
        for (radio.bonds) |slot| {
            if (slot) |bond| {
                if (bond.address != address) continue;
                if (bond.link_key != presented_key) return .key_mismatch;
                return null;
            }
        }
        return .not_bonded;
    }

    /// Forgets a bonded device, so it must be paired again to reconnect.
    pub fn forget(radio: *Radio, address: Address) void {
        for (&radio.bonds) |*slot| {
            if (slot.*) |bond| {
                if (bond.address == address) slot.* = null;
            }
        }
    }

    pub fn isBonded(radio: Radio, address: Address) bool {
        for (radio.bonds) |slot| {
            if (slot) |bond| {
                if (bond.address == address) return true;
            }
        }
        return false;
    }
};

const testing = std.testing;

test "an authorized, matched pairing bonds a device that can then reconnect" {
    var radio: Radio = .{};
    try testing.expect(radio.pair(0x1122, 0xABCD, true, true) == null);
    try testing.expect(radio.isBonded(0x1122));
    try testing.expect(radio.connect(0x1122, 0xABCD) == null);
}

test "pairing is refused without authorization or a matching comparison" {
    var radio: Radio = .{};
    try testing.expectEqual(PairError.not_authorized, radio.pair(0x1, 1, false, true).?);
    try testing.expectEqual(PairError.comparison_mismatch, radio.pair(0x1, 1, true, false).?);
    try testing.expect(!radio.isBonded(0x1));
}

test "an impostor with the right address but the wrong key is refused" {
    var radio: Radio = .{};
    _ = radio.pair(0x1122, 0xABCD, true, true);
    try testing.expectEqual(ConnectRefusal.key_mismatch, radio.connect(0x1122, 0x9999).?);
    try testing.expectEqual(ConnectRefusal.not_bonded, radio.connect(0x3344, 0xABCD).?);
}

test "a forgotten device must pair again" {
    var radio: Radio = .{};
    _ = radio.pair(0x1122, 0xABCD, true, true);
    radio.forget(0x1122);
    try testing.expect(!radio.isBonded(0x1122));
    try testing.expectEqual(ConnectRefusal.not_bonded, radio.connect(0x1122, 0xABCD).?);
}
