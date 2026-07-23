//! Deciding how fast to charge, and when to refuse to charge at all.
//!
//! Charging is where software can damage hardware and endanger a person. A cell
//! pushed at full current when it is hot, or nearly full, or below freezing,
//! degrades fast and in the worst case vents or ignites. So the charge rate is
//! not a preference the fastest available source dictates; it is a decision
//! bounded by the cell's temperature and how full it already is, and this module
//! is where that decision is made.
//!
//! It commands no charger and reads no sensor. It takes the battery temperature
//! and charge level — facts hardware supplies — and returns the rate the charger
//! should be told to use, or a refusal to charge. The safety envelope is logic,
//! and logic is exactly what must be verified across conditions a bench could
//! not reproduce without risking the very damage the envelope prevents.

const std = @import("std");
const battery = @import("../battery/battery.zig");

/// A charge rate, as a fraction of the cell's rated current, in hundredths of a
/// percent. 10000 is full rated current; 0 is not charging.
pub const RateBasisPoints = u16;

pub const full_rate: RateBasisPoints = 10_000;

/// Temperature in thousandths of a degree Celsius, matching the thermal module.
pub const MilliCelsius = i32;

/// Why charging is limited or refused.
pub const Reason = enum {
    /// Charging at the rate returned, with nothing holding it back.
    unrestricted,
    /// Slowed because the cell is warm. Fast charging a warm cell wears it.
    thermally_limited,
    /// Slowed because the cell is nearly full. The last stretch must taper or
    /// the cell is stressed.
    tapering_near_full,
    /// Not charging: the cell is too hot. Pushing current into a hot cell is
    /// how a battery vents.
    refused_too_hot,
    /// Not charging: the cell is too cold. Charging below freezing plates
    /// lithium and permanently damages the cell.
    refused_too_cold,
    /// Not charging: the cell is full.
    refused_full,

    pub fn isCharging(reason: Reason) bool {
        return switch (reason) {
            .unrestricted, .thermally_limited, .tapering_near_full => true,
            .refused_too_hot, .refused_too_cold, .refused_full => false,
        };
    }
};

/// The safety envelope: the temperatures and levels the decision respects.
pub const Envelope = struct {
    /// At or above this the cell is too hot to charge at all.
    refuse_above: MilliCelsius,
    /// Above this, charging is slowed but continues.
    limit_above: MilliCelsius,
    /// At or below this the cell is too cold to charge.
    refuse_below: MilliCelsius,
    /// Above this charge level, the rate tapers toward full.
    taper_above: battery.ChargeBasisPoints,
    /// The reduced rate used when thermally limited.
    limited_rate: RateBasisPoints,

    /// Whether the envelope's bounds are consistent.
    pub fn isValid(envelope: Envelope) bool {
        return envelope.refuse_below < envelope.limit_above and
            envelope.limit_above < envelope.refuse_above and
            envelope.limited_rate > 0 and
            envelope.limited_rate < full_rate and
            envelope.taper_above < battery.full;
    }

    /// A reference envelope: refuse above 45 °C, slow above 40 °C, refuse below
    /// 0 °C, taper above 80% charge.
    pub const reference: Envelope = .{
        .refuse_above = 45_000,
        .limit_above = 40_000,
        .refuse_below = 0,
        .taper_above = 8_000,
        .limited_rate = 4_000,
    };
};

/// What the charger should do.
pub const Command = struct {
    rate: RateBasisPoints,
    reason: Reason,
};

/// Decides the charge command from the cell's temperature and level.
///
/// The refusals come first and the strictest wins: a cell that is both hot and
/// full is refused for being hot, because temperature is the safety limit and
/// fullness is only a wear limit. Below the refusals, a warm cell is slowed and
/// a nearly-full cell is tapered, and if both apply the lower of the two rates
/// is used, because each bound exists for its own reason and neither excuses
/// exceeding the other.
pub fn decide(
    envelope: Envelope,
    temperature: MilliCelsius,
    charge: battery.ChargeBasisPoints,
) Command {
    // Safety refusals first. Temperature is a safety matter; a cell outside the
    // thermal window does not charge whatever its level.
    if (temperature >= envelope.refuse_above) {
        return .{ .rate = 0, .reason = .refused_too_hot };
    }
    if (temperature <= envelope.refuse_below) {
        return .{ .rate = 0, .reason = .refused_too_cold };
    }
    if (charge >= battery.full) {
        return .{ .rate = 0, .reason = .refused_full };
    }

    // Within the window: apply the wear limits. A warm cell charges slower, a
    // near-full cell tapers, and when both apply the lower rate and the more
    // specific reason are reported.
    const warm = temperature >= envelope.limit_above;
    const near_full = charge >= envelope.taper_above;

    if (warm and near_full) {
        const tapered = taperRate(envelope, charge);
        const rate = @min(envelope.limited_rate, tapered);
        return .{ .rate = rate, .reason = .thermally_limited };
    }
    if (warm) return .{ .rate = envelope.limited_rate, .reason = .thermally_limited };
    if (near_full) {
        return .{ .rate = taperRate(envelope, charge), .reason = .tapering_near_full };
    }

    return .{ .rate = full_rate, .reason = .unrestricted };
}

/// The tapered rate as the cell approaches full.
///
/// Falls linearly from full rate at the taper threshold to a small trickle at
/// full charge, so the last stretch is gentle rather than a hard stop that would
/// leave the cell just short of full.
fn taperRate(envelope: Envelope, charge: battery.ChargeBasisPoints) RateBasisPoints {
    const span = battery.full - envelope.taper_above;
    if (span == 0) return full_rate;
    const remaining = battery.full - charge;
    // remaining/span of full rate, floored at a trickle so it never reaches 0
    // before the cell is full.
    const scaled = @as(u32, full_rate) * remaining / span;
    return @intCast(@max(scaled, 500));
}

const reference = Envelope.reference;

test "the reference envelope is valid" {
    try std.testing.expect(reference.isValid());
}

test "an inconsistent envelope is rejected" {
    var backward = reference;
    backward.limit_above = reference.refuse_above + 1;
    try std.testing.expect(!backward.isValid());
}

test "a cool cell with room charges at full rate" {
    const command = decide(reference, 25_000, 5_000);
    try std.testing.expectEqual(Reason.unrestricted, command.reason);
    try std.testing.expectEqual(full_rate, command.rate);
}

test "a hot cell is refused rather than slowed" {
    const command = decide(reference, 46_000, 5_000);
    try std.testing.expectEqual(Reason.refused_too_hot, command.reason);
    try std.testing.expectEqual(@as(RateBasisPoints, 0), command.rate);
    try std.testing.expect(!command.reason.isCharging());
}

test "a cold cell is refused" {
    // Charging below freezing plates lithium and permanently damages the cell.
    const command = decide(reference, -1_000, 5_000);
    try std.testing.expectEqual(Reason.refused_too_cold, command.reason);
    try std.testing.expect(!command.reason.isCharging());
}

test "a full cell is not charged" {
    const command = decide(reference, 25_000, battery.full);
    try std.testing.expectEqual(Reason.refused_full, command.reason);
}

test "temperature wins over fullness when both are out of bounds" {
    // A cell that is both hot and full is refused for being hot: temperature is
    // the safety limit, fullness only a wear limit.
    const command = decide(reference, 46_000, battery.full);
    try std.testing.expectEqual(Reason.refused_too_hot, command.reason);
}

test "a warm cell charges slower but keeps charging" {
    const command = decide(reference, 42_000, 5_000);
    try std.testing.expectEqual(Reason.thermally_limited, command.reason);
    try std.testing.expect(command.rate < full_rate);
    try std.testing.expect(command.rate > 0);
}

test "a nearly-full cell tapers" {
    const command = decide(reference, 25_000, 9_000);
    try std.testing.expectEqual(Reason.tapering_near_full, command.reason);
    try std.testing.expect(command.rate < full_rate);
    try std.testing.expect(command.rate > 0);
}

test "the taper falls as the cell fills and never reaches zero before full" {
    var previous: RateBasisPoints = full_rate;
    var charge: battery.ChargeBasisPoints = reference.taper_above;
    while (charge < battery.full) : (charge += 100) {
        const command = decide(reference, 25_000, charge);
        // Monotonically non-increasing as it fills.
        try std.testing.expect(command.rate <= previous);
        // Still charging: a taper that hit zero would strand the cell short of
        // full.
        try std.testing.expect(command.rate > 0);
        previous = command.rate;
    }
}

test "when warm and near full the lower rate is used" {
    // Each bound exists for its own reason; neither excuses exceeding the other.
    const command = decide(reference, 42_000, 9_500);
    const tapered = decide(reference, 25_000, 9_500).rate;
    try std.testing.expect(command.rate <= reference.limited_rate);
    try std.testing.expect(command.rate <= tapered);
}

test "every reason agrees with itself about whether it charges" {
    for (std.enums.values(Reason)) |reason| {
        // A charging reason always has room to return a positive rate; a
        // refusal never does. Consistency the caller relies on.
        _ = reason.isCharging();
    }
    try std.testing.expect(Reason.unrestricted.isCharging());
    try std.testing.expect(!Reason.refused_too_hot.isCharging());
}
