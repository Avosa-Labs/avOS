//! Choosing the device's power mode from battery, charge, and heat, and deciding
//! what work each mode allows, so the device protects its own endurance and
//! temperature without a person having to manage it.
//!
//! A device has a finite battery and a temperature it must not exceed, and both
//! are spent by the same thing: work. Left ungoverned, a device runs every request
//! at full speed until the battery is flat at midday or the case is too hot to
//! hold — so the system chooses a power mode from the conditions and lets that mode
//! decide which work may run. The choice is a priority order, not a blend: heat
//! comes first, because a device that overheats must shed load whatever its
//! battery, then a critically low battery, because preserving the last few percent
//! for the things a person truly needs outranks convenience. Above those, charging
//! frees the device to run fast, and on battery it stays balanced. What each mode
//! then permits is graded: essential work always runs, and speculative background
//! work is the first thing dropped as the device tightens its belt.
//!
//! This module changes no clock speed and runs no task. It maps conditions to a
//! power mode and answers whether a class of work may run in that mode, as pure
//! functions so the same conditions always yield the same posture.

const std = @import("std");

/// How hot the device is, from its thermal sensors.
pub const Thermal = enum {
    /// Normal operating temperature.
    nominal,
    /// Warm: begin shedding non-essential load before it becomes a problem.
    warm,
    /// Hot: shed aggressively; sustained work here risks the temperature limit.
    hot,
    /// At the limit: only work that cannot be stopped continues.
    critical,
};

/// The device's power posture, which grades how much work it will do.
pub const Mode = enum {
    /// Plugged in and cool: run at full speed, all work permitted.
    performance,
    /// On battery, normal conditions: a sustainable middle.
    balanced,
    /// Battery low or device warm: drop speculative work, slow the rest.
    low_power,
    /// Battery critical or device hot: only essential work, everything else waits.
    critical_saver,
};

/// The battery level at or below which the device enters its critical saver,
/// reserving the remainder for what a person truly needs.
pub const battery_critical_percent: u8 = 10;

/// The battery level below which, off charge, the device drops to low power.
pub const battery_low_percent: u8 = 25;

/// The conditions a power mode is chosen from.
pub const Conditions = struct {
    battery_percent: u8,
    charging: bool,
    thermal: Thermal,
};

/// Chooses the power mode for the given conditions.
///
/// Heat is considered first: a critical temperature forces the saver and a hot
/// device forces low power, whatever the battery, because temperature is a safety
/// limit and endurance is not. Then a critically low battery forces the saver even
/// while charging, because the charge may not keep pace with the load. With heat
/// and critical battery handled, charging permits performance and a merely low
/// battery on its own drops to low power; otherwise the device runs balanced.
pub fn selectMode(conditions: Conditions) Mode {
    // Thermal takes precedence over everything: it is a safety limit.
    switch (conditions.thermal) {
        .critical => return .critical_saver,
        .hot => return .low_power,
        .warm, .nominal => {},
    }

    if (conditions.battery_percent <= battery_critical_percent) return .critical_saver;

    if (conditions.charging) return .performance;

    if (conditions.battery_percent < battery_low_percent) return .low_power;
    if (conditions.thermal == .warm) return .low_power;
    return .balanced;
}

/// A class of work, graded by how essential it is, so a mode can admit or drop it.
pub const WorkClass = enum {
    /// Work a person is waiting on right now, or that keeps the device safe and
    /// reachable. Always runs.
    essential,
    /// Committed work a person requested but is not watching: a download, a sync.
    /// Runs except under the tightest belt.
    committed,
    /// Speculative, proactive work with no one waiting: prefetch, indexing. The
    /// first thing dropped.
    speculative,

    fn tier(class: WorkClass) u8 {
        return switch (class) {
            .essential => 2,
            .committed => 1,
            .speculative => 0,
        };
    }
};

/// Whether a mode permits a class of work.
///
/// Essential work runs in every mode, because stopping it would make the device
/// unsafe or unresponsive. Committed work runs until the critical saver, where only
/// the essential continues. Speculative work runs only when the device has power to
/// spare — performance and balanced — and is dropped the moment the device begins
/// conserving. The grading is monotone: a tighter mode never permits more than a
/// looser one.
pub fn permits(mode: Mode, class: WorkClass) bool {
    const floor: u8 = switch (mode) {
        .performance, .balanced => 0, // everything, including speculative
        .low_power => 1, // committed and essential
        .critical_saver => 2, // essential only
    };
    return class.tier() >= floor;
}

fn makeConditions(battery: u8, charging: bool, thermal: Thermal) Conditions {
    return .{ .battery_percent = battery, .charging = charging, .thermal = thermal };
}

test "plugged in and cool runs at performance" {
    try std.testing.expectEqual(Mode.performance, selectMode(makeConditions(80, true, .nominal)));
}

test "on battery in normal conditions is balanced" {
    try std.testing.expectEqual(Mode.balanced, selectMode(makeConditions(80, false, .nominal)));
}

test "a low battery off charge drops to low power" {
    try std.testing.expectEqual(Mode.low_power, selectMode(makeConditions(20, false, .nominal)));
}

test "a critical battery forces the saver even while charging" {
    // The charge may not keep pace; preserve the remainder.
    try std.testing.expectEqual(Mode.critical_saver, selectMode(makeConditions(8, true, .nominal)));
}

test "heat overrides battery: a hot device drops to low power on a full battery" {
    try std.testing.expectEqual(Mode.low_power, selectMode(makeConditions(100, true, .hot)));
}

test "a critical temperature forces the saver whatever the power" {
    try std.testing.expectEqual(Mode.critical_saver, selectMode(makeConditions(100, true, .critical)));
}

test "a warm device on battery drops to low power" {
    try std.testing.expectEqual(Mode.low_power, selectMode(makeConditions(80, false, .warm)));
}

test "a warm device while charging still runs performance" {
    // Warm is only a demotion on battery; on charge the device can afford it, and
    // the thermal switch reserves warm for the battery path.
    try std.testing.expectEqual(Mode.performance, selectMode(makeConditions(80, true, .warm)));
}

test "essential work runs in every mode" {
    for ([_]Mode{ .performance, .balanced, .low_power, .critical_saver }) |mode| {
        try std.testing.expect(permits(mode, .essential));
    }
}

test "speculative work runs only when there is power to spare" {
    try std.testing.expect(permits(.performance, .speculative));
    try std.testing.expect(permits(.balanced, .speculative));
    try std.testing.expect(!permits(.low_power, .speculative));
    try std.testing.expect(!permits(.critical_saver, .speculative));
}

test "committed work runs until the critical saver" {
    try std.testing.expect(permits(.low_power, .committed));
    try std.testing.expect(!permits(.critical_saver, .committed));
}

test "the grading is monotone: a tighter mode never permits more, swept" {
    // Ordered tightest to loosest; whatever a tighter mode permits, a looser one
    // permits too.
    const order = [_]Mode{ .critical_saver, .low_power, .balanced, .performance };
    const classes = [_]WorkClass{ .essential, .committed, .speculative };
    for (order, 0..) |tighter, i| {
        for (order[i..]) |looser| {
            for (classes) |class| {
                if (permits(tighter, class)) try std.testing.expect(permits(looser, class));
            }
        }
    }
}

test "thermal precedence holds whatever the battery, swept" {
    // A critical temperature always yields the saver; a hot one never yields
    // performance or balanced, regardless of battery or charge.
    var battery: u8 = 0;
    while (battery <= 100) : (battery += 10) {
        for ([_]bool{ false, true }) |charging| {
            try std.testing.expectEqual(Mode.critical_saver, selectMode(makeConditions(battery, charging, .critical)));
            const hot = selectMode(makeConditions(battery, charging, .hot));
            try std.testing.expect(hot == .low_power or hot == .critical_saver);
        }
    }
}
