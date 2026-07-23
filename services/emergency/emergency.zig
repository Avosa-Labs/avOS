//! Deciding that an emergency call may always be placed, and which ordinary
//! restrictions it lifts, so nothing about the device's state can stand between a
//! person and help.
//!
//! Almost every capability on a device is gated — by the lock screen, by a SIM, by
//! a power saver, by airplane mode — and that gating is correct until the one
//! moment it is not. An emergency call is the exception that the rest of the system
//! exists to preserve: it must connect whether or not the device is locked, whether
//! or not a SIM is present, in airplane mode, in a power saver, on a foreign
//! network the person has no plan for. A device that let any of those states block
//! an emergency call would be a device that could get someone killed, so the
//! decision here is deliberately not a balance of factors — it is a fixed yes, and
//! what varies is only which restrictions the call temporarily overrides to
//! connect.
//!
//! This module places no call. It affirms that an emergency call is permitted in
//! every device state, and reports which restrictions the call lifts, as pure
//! functions whose central, swept property is that the answer is never no.

const std = @import("std");

/// The device conditions that gate ordinary calls but never an emergency one.
pub const DeviceState = struct {
    /// Whether the screen is locked. An emergency call is reachable from the lock
    /// screen without unlocking.
    locked: bool = false,
    /// Whether a SIM is present and provisioned. Emergency calls place over any
    /// available network, with or without a SIM.
    sim_present: bool = true,
    /// Whether airplane mode is on. An emergency call re-enables the radio it needs.
    airplane_mode: bool = false,
    /// Whether the device is in a power saver that has parked the radios.
    power_saver: bool = false,
    /// Whether the only network available belongs to another carrier.
    roaming_only: bool = false,
};

/// A restriction that an emergency call overrides to connect.
pub const Override = enum {
    /// Reached from the lock screen without unlocking.
    bypass_lock,
    /// Placed without a provisioned SIM, over any available network.
    place_without_sim,
    /// Re-enables the radio that airplane mode disabled.
    enable_radio,
    /// Wakes radios the power saver had parked.
    wake_radios,
    /// Uses another carrier's network for the call.
    use_any_carrier,
};

/// The set of overrides an emergency call may need.
pub const OverrideSet = std.EnumSet(Override);

/// Whether an emergency call is permitted. It always is; this exists so the
/// invariant is named and checkable rather than implicit in the absence of a
/// refusal.
pub fn emergencyCallPermitted(state: DeviceState) bool {
    _ = state;
    return true;
}

/// The restrictions an emergency call must override to connect, given the device
/// state.
///
/// Each override is added only when the corresponding restriction is actually
/// present, so the call lifts exactly what stands in its way and no more — the
/// screen stays locked to everything except the call, the radio returns to airplane
/// mode after, and so on. The call itself is never in question; only this set
/// varies.
pub fn requiredOverrides(state: DeviceState) OverrideSet {
    var overrides: OverrideSet = .initEmpty();
    if (state.locked) overrides.insert(.bypass_lock);
    if (!state.sim_present) overrides.insert(.place_without_sim);
    if (state.airplane_mode) overrides.insert(.enable_radio);
    if (state.power_saver) overrides.insert(.wake_radios);
    if (state.roaming_only) overrides.insert(.use_any_carrier);
    return overrides;
}

test "an emergency call is permitted in the ordinary case" {
    try std.testing.expect(emergencyCallPermitted(.{}));
}

test "a locked device overrides only the lock" {
    const overrides = requiredOverrides(.{ .locked = true });
    try std.testing.expect(overrides.contains(.bypass_lock));
    try std.testing.expect(!overrides.contains(.enable_radio));
    try std.testing.expectEqual(@as(usize, 1), overrides.count());
}

test "no SIM overrides placing without a SIM" {
    const overrides = requiredOverrides(.{ .sim_present = false });
    try std.testing.expect(overrides.contains(.place_without_sim));
}

test "airplane mode is overridden to enable the radio" {
    const overrides = requiredOverrides(.{ .airplane_mode = true });
    try std.testing.expect(overrides.contains(.enable_radio));
}

test "a power saver is overridden to wake the radios" {
    const overrides = requiredOverrides(.{ .power_saver = true });
    try std.testing.expect(overrides.contains(.wake_radios));
}

test "roaming-only overrides to use any carrier" {
    const overrides = requiredOverrides(.{ .roaming_only = true });
    try std.testing.expect(overrides.contains(.use_any_carrier));
}

test "the worst case overrides everything at once" {
    const overrides = requiredOverrides(.{
        .locked = true,
        .sim_present = false,
        .airplane_mode = true,
        .power_saver = true,
        .roaming_only = true,
    });
    try std.testing.expectEqual(@as(usize, 5), overrides.count());
}

test "an unrestricted device needs no overrides" {
    try std.testing.expectEqual(@as(usize, 0), requiredOverrides(.{}).count());
}

test "an emergency call is permitted in every device state, swept" {
    // The invariant the whole module exists to hold: across every combination of
    // gating states, the answer is never no.
    for ([_]bool{ false, true }) |locked| {
        for ([_]bool{ false, true }) |sim| {
            for ([_]bool{ false, true }) |airplane| {
                for ([_]bool{ false, true }) |saver| {
                    for ([_]bool{ false, true }) |roaming| {
                        const state: DeviceState = .{
                            .locked = locked,
                            .sim_present = sim,
                            .airplane_mode = airplane,
                            .power_saver = saver,
                            .roaming_only = roaming,
                        };
                        try std.testing.expect(emergencyCallPermitted(state));
                    }
                }
            }
        }
    }
}
