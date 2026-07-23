//! Deciding when an already-prepared update may be applied, and whether to keep it
//! once applied, so an update never strands a person on a dead battery or a broken
//! boot.
//!
//! The update model below this makes an update atomic and reversible; what it does
//! not decide is the moment. Applying an update is the one operation that can leave
//! a device briefly unusable while it reboots into the new image, so the moment
//! matters: apply it on a nearly flat battery and the reboot may not finish, apply
//! it while the person is mid-task and the interruption is the update's fault, pull
//! a large image over a metered link and the person pays for it. So an update
//! waits for conditions that make applying safe and unobtrusive, with one
//! exception — a critical security fix relaxes the comfort gates, because the risk
//! of not applying it outweighs the inconvenience. And once applied, the update is
//! kept only if the device comes back healthy; a boot loop or a failed service
//! rolls back to the slot that was working.
//!
//! This module applies nothing. It decides whether conditions permit applying a
//! staged update, and whether a post-apply health report should be committed or
//! rolled back, as pure functions over the device conditions and the update's
//! urgency.

const std = @import("std");

/// How urgent an update is, which sets how many comfort gates it may skip.
pub const Urgency = enum {
    /// A routine update. Waits for every condition to be comfortable.
    routine,
    /// A critical security fix. Relaxes the comfort gates — metered network, device
    /// busy — because delaying it is the greater risk. It still respects the hard
    /// safety floor on battery, because a failed apply helps no one.
    critical_security,

    fn relaxesComfort(urgency: Urgency) bool {
        return urgency == .critical_security;
    }
};

/// The device conditions an apply decision is made against.
pub const Conditions = struct {
    /// Battery charge, 0 to 100.
    battery_percent: u8,
    /// Whether the device is on external power.
    charging: bool,
    /// Whether the current network is unmetered.
    unmetered_network: bool,
    /// Free storage in bytes, which must exceed the image size to stage safely.
    storage_available_bytes: u64,
    /// Whether the person is actively using the device right now.
    device_busy: bool,
};

/// The hard battery floor below which an update is never applied on battery, even
/// a critical one: a reboot that runs out of power mid-apply is the worst outcome.
pub const battery_hard_floor_percent: u8 = 20;

/// The comfortable battery level for a routine update on battery.
pub const battery_comfortable_percent: u8 = 50;

/// Why an apply was deferred.
pub const Deferral = enum {
    /// Battery is below the hard floor and the device is not charging. Never
    /// skipped, at any urgency.
    battery_too_low,
    /// Battery is below the comfortable level for a routine update not on charge.
    awaiting_charge,
    /// The network is metered and this is not a critical update.
    awaiting_unmetered_network,
    /// Not enough free storage to stage the image.
    insufficient_storage,
    /// The person is using the device and this is not a critical update.
    device_in_use,
};

/// The decision about applying a staged update.
pub const ApplyDecision = union(enum) {
    apply,
    defer_until: Deferral,

    pub fn applies(decision: ApplyDecision) bool {
        return decision == .apply;
    }
};

/// Decides whether a staged update of `size_bytes` may be applied now.
///
/// The hard battery floor is absolute: below it and not charging, no update
/// applies, whatever its urgency, because a reboot that loses power part way is
/// unrecoverable in the way the whole design exists to avoid. Storage is likewise
/// non-negotiable. The remaining gates are comfort: a routine update waits for a
/// comfortable charge, an unmetered network, and an idle device; a critical
/// security fix skips those, because the exposure of delaying it outweighs the
/// inconvenience.
pub fn readyToApply(conditions: Conditions, size_bytes: u64, urgency: Urgency) ApplyDecision {
    // Absolute safety gates, never skipped.
    if (!conditions.charging and conditions.battery_percent < battery_hard_floor_percent) {
        return .{ .defer_until = .battery_too_low };
    }
    if (conditions.storage_available_bytes < size_bytes) {
        return .{ .defer_until = .insufficient_storage };
    }

    if (urgency.relaxesComfort()) return .apply;

    // Comfort gates for a routine update.
    if (!conditions.charging and conditions.battery_percent < battery_comfortable_percent) {
        return .{ .defer_until = .awaiting_charge };
    }
    if (!conditions.unmetered_network) return .{ .defer_until = .awaiting_unmetered_network };
    if (conditions.device_busy) return .{ .defer_until = .device_in_use };
    return .apply;
}

/// A health report gathered after an update is applied and the device reboots.
pub const Health = struct {
    /// Whether the device completed boot into the new image.
    booted: bool,
    /// Whether every critical service came up.
    services_healthy: bool,
    /// How many times the device restarted unexpectedly since the apply. A boot
    /// loop shows here.
    unexpected_restarts: u8,

    /// The most unexpected restarts tolerated before the update is judged bad.
    pub const restart_tolerance: u8 = 2;
};

/// Whether a post-apply health report should be committed or rolled back.
pub const HealthDecision = enum {
    /// The device is healthy on the new image; make the switch permanent.
    commit,
    /// The device is not healthy; return to the slot that was working.
    rollback,
};

/// Decides whether to keep an applied update.
///
/// The update is committed only if the device booted, its services came up, and it
/// has not exceeded the restart tolerance. Any of those failing rolls back, because
/// the guarantee that makes updating safe is that a bad update returns to a working
/// state rather than leaving the device degraded on the new one.
pub fn evaluateHealth(health: Health) HealthDecision {
    if (!health.booted) return .rollback;
    if (!health.services_healthy) return .rollback;
    if (health.unexpected_restarts > Health.restart_tolerance) return .rollback;
    return .commit;
}

const one_gib: u64 = 1 << 30;

fn makeConditions(battery: u8, charging: bool, unmetered: bool, storage: u64, busy: bool) Conditions {
    return .{
        .battery_percent = battery,
        .charging = charging,
        .unmetered_network = unmetered,
        .storage_available_bytes = storage,
        .device_busy = busy,
    };
}

test "a routine update applies when everything is comfortable" {
    const c = makeConditions(80, false, true, 4 * one_gib, false);
    try std.testing.expect(readyToApply(c, one_gib, .routine).applies());
}

test "a routine update defers below a comfortable battery off charge" {
    const c = makeConditions(40, false, true, 4 * one_gib, false);
    try std.testing.expectEqual(ApplyDecision{ .defer_until = .awaiting_charge }, readyToApply(c, one_gib, .routine));
}

test "a routine update on charge ignores the comfortable-battery gate" {
    // Charging: a low-but-above-floor battery is fine because power is coming in.
    const c = makeConditions(30, true, true, 4 * one_gib, false);
    try std.testing.expect(readyToApply(c, one_gib, .routine).applies());
}

test "a routine update defers on a metered network" {
    const c = makeConditions(80, false, false, 4 * one_gib, false);
    try std.testing.expectEqual(ApplyDecision{ .defer_until = .awaiting_unmetered_network }, readyToApply(c, one_gib, .routine));
}

test "a routine update defers while the device is in use" {
    const c = makeConditions(80, false, true, 4 * one_gib, true);
    try std.testing.expectEqual(ApplyDecision{ .defer_until = .device_in_use }, readyToApply(c, one_gib, .routine));
}

test "a critical update skips the comfort gates" {
    // Metered, busy, low-but-above-floor battery off charge: a critical fix still
    // applies because delaying it is the greater risk.
    const c = makeConditions(30, false, false, 4 * one_gib, true);
    try std.testing.expect(readyToApply(c, one_gib, .critical_security).applies());
}

test "even a critical update respects the hard battery floor off charge" {
    const c = makeConditions(15, false, false, 4 * one_gib, true);
    try std.testing.expectEqual(ApplyDecision{ .defer_until = .battery_too_low }, readyToApply(c, one_gib, .critical_security));
}

test "the hard floor is skipped only by charging, not by urgency" {
    // On charge at 15%, even routine may proceed past the floor (it then hits the
    // comfort gate instead, which charging clears).
    const charging_low = makeConditions(15, true, true, 4 * one_gib, false);
    try std.testing.expect(readyToApply(charging_low, one_gib, .routine).applies());
}

test "insufficient storage defers any update" {
    const c = makeConditions(90, true, true, one_gib / 2, false);
    try std.testing.expectEqual(ApplyDecision{ .defer_until = .insufficient_storage }, readyToApply(c, one_gib, .critical_security));
}

test "a healthy device commits the update" {
    try std.testing.expectEqual(HealthDecision.commit, evaluateHealth(.{ .booted = true, .services_healthy = true, .unexpected_restarts = 0 }));
    // Within the restart tolerance still commits.
    try std.testing.expectEqual(HealthDecision.commit, evaluateHealth(.{ .booted = true, .services_healthy = true, .unexpected_restarts = Health.restart_tolerance }));
}

test "a device that did not boot rolls back" {
    try std.testing.expectEqual(HealthDecision.rollback, evaluateHealth(.{ .booted = false, .services_healthy = false, .unexpected_restarts = 0 }));
}

test "unhealthy services roll back" {
    try std.testing.expectEqual(HealthDecision.rollback, evaluateHealth(.{ .booted = true, .services_healthy = false, .unexpected_restarts = 0 }));
}

test "a boot loop rolls back" {
    try std.testing.expectEqual(HealthDecision.rollback, evaluateHealth(.{ .booted = true, .services_healthy = true, .unexpected_restarts = Health.restart_tolerance + 1 }));
}

test "no update ever applies below the hard floor off charge, swept" {
    // The unrecoverable-reboot property: whatever the urgency and other conditions,
    // an off-charge battery under the hard floor never applies.
    for ([_]Urgency{ .routine, .critical_security }) |urgency| {
        var battery: u8 = 0;
        while (battery < battery_hard_floor_percent) : (battery += 1) {
            const c = makeConditions(battery, false, true, 8 * one_gib, false);
            try std.testing.expect(!readyToApply(c, one_gib, urgency).applies());
        }
    }
}
