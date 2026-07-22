//! Reading how hot the device is, and what the system may do about it.
//!
//! Energy and thermal figures are the one place this project cannot measure
//! what it needs to. A power number needs a rail sensor or an external meter,
//! and a temperature number needs a real die on a real board. This module is
//! the interface those measurements arrive through, not the measurements: a
//! reading comes from a sensor the board provides, and the software above it
//! decides what a reading means.
//!
//! Separating the two matters because thermal *policy* is testable and thermal
//! *values* are not. Whether the system throttles at the right threshold, in
//! the right order, and recovers when it cools is logic this module holds and
//! tests. What temperature the die actually reaches under load is a fact only
//! hardware can supply, and this module refuses to invent it.
//!
//! There is no software stand-in that reports plausible temperatures. A fake
//! sensor that returned believable numbers would let every layer above it be
//! tested against a guarantee it was not getting, and worse, would make the
//! absent hardware measurement look present. A test sensor exists, and it
//! reports exactly the value a test sets, so a test drives policy rather than
//! trusting a number nobody measured.

const std = @import("std");

/// A temperature in thousandths of a degree Celsius.
///
/// Integer millidegrees rather than a float, so a reading compares and
/// serializes identically on every host and a threshold means the same thing
/// twice.
pub const MilliCelsius = i32;

/// Where a reading came from on the board.
///
/// Distinct zones because they heat and cool independently: a hot modem does
/// not mean a hot battery, and throttling the wrong one wastes performance
/// without fixing the problem.
pub const Zone = enum {
    /// The main processor.
    compute,
    /// The cellular and wireless radios.
    radio,
    /// The battery, whose limits are a safety matter rather than a performance
    /// one.
    battery,
    /// The outside surface a person touches.
    skin,
};

/// How the system should respond to how hot a zone is.
///
/// Ordered from least to most severe, so a comparison decides which of two
/// responses wins when zones disagree: the more severe one always does.
pub const Response = enum(u8) {
    /// Run normally.
    nominal = 0,
    /// Shed background work and dim what can be dimmed.
    ease = 1,
    /// Reduce clocks and refuse new heavy work.
    throttle = 2,
    /// Stop everything but what keeps the device safe and reachable, including
    /// an emergency call.
    protect = 3,
    /// Power down. The only response that risks data, and the only one that
    /// prevents damage a running device could do to itself or its owner.
    shut_down = 4,

    pub fn isMoreSevereThan(response: Response, other: Response) bool {
        return @intFromEnum(response) > @intFromEnum(other);
    }
};

/// The thresholds for one zone.
///
/// Each threshold is where a response *begins*; the system stays in that
/// response until the temperature falls back below the threshold by the
/// hysteresis margin. Without that margin a device sitting exactly at a
/// threshold would flap between two responses many times a second.
pub const Thresholds = struct {
    ease_at: MilliCelsius,
    throttle_at: MilliCelsius,
    protect_at: MilliCelsius,
    shut_down_at: MilliCelsius,
    /// How far a zone must cool before a response relaxes. Never zero.
    hysteresis: MilliCelsius,

    /// Whether the thresholds are ordered the way a response ladder requires.
    ///
    /// Checked rather than assumed: thresholds out of order would let a hotter
    /// reading select a milder response, which is the one failure this whole
    /// mechanism exists to prevent.
    pub fn areOrdered(thresholds: Thresholds) bool {
        return thresholds.ease_at < thresholds.throttle_at and
            thresholds.throttle_at < thresholds.protect_at and
            thresholds.protect_at < thresholds.shut_down_at and
            thresholds.hysteresis > 0;
    }
};

/// A source of temperature readings for one zone.
///
/// An interface, because a reading is a hardware fact. On a board this is a
/// sensor; in a test it is a value a test sets. There is deliberately no
/// implementation that reports plausible numbers on a host without a sensor.
pub const Sensor = struct {
    context_pointer: *anyopaque,
    readFn: *const fn (context_pointer: *anyopaque) ?MilliCelsius,

    /// The current temperature, or null if the sensor cannot be read.
    ///
    /// A sensor that cannot be read is not the same as a cool one. A missing
    /// reading is treated as the most severe response the zone allows, because
    /// a device that cannot tell how hot it is must assume the worst rather
    /// than run blind.
    pub fn read(sensor: Sensor) ?MilliCelsius {
        return sensor.readFn(sensor.context_pointer);
    }
};

/// Decides a zone's response from a reading and the response it is already in.
///
/// The current response is an input because of hysteresis: relaxing happens at
/// a lower temperature than escalating, so the same reading can mean different
/// things depending on which way the device is heading.
pub fn responseFor(
    thresholds: Thresholds,
    current: Response,
    reading: ?MilliCelsius,
) Response {
    // A zone that cannot be read is assumed to be as hot as it is allowed to
    // get. Running blind is the one thing thermal management must never do.
    const temperature = reading orelse return .protect;

    const escalated = escalate(thresholds, temperature);
    if (escalated.isMoreSevereThan(current)) return escalated;

    // Cooling: stay in the current response until the temperature has fallen
    // below its threshold by the hysteresis margin.
    return relax(thresholds, current, temperature);
}

fn escalate(thresholds: Thresholds, temperature: MilliCelsius) Response {
    if (temperature >= thresholds.shut_down_at) return .shut_down;
    if (temperature >= thresholds.protect_at) return .protect;
    if (temperature >= thresholds.throttle_at) return .throttle;
    if (temperature >= thresholds.ease_at) return .ease;
    return .nominal;
}

fn relax(thresholds: Thresholds, current: Response, temperature: MilliCelsius) Response {
    const margin = thresholds.hysteresis;
    return switch (current) {
        .nominal => .nominal,
        .ease => if (temperature < thresholds.ease_at - margin) .nominal else .ease,
        .throttle => if (temperature < thresholds.throttle_at - margin)
            relax(thresholds, .ease, temperature)
        else
            .throttle,
        .protect => if (temperature < thresholds.protect_at - margin)
            relax(thresholds, .throttle, temperature)
        else
            .protect,
        .shut_down => if (temperature < thresholds.shut_down_at - margin)
            relax(thresholds, .protect, temperature)
        else
            .shut_down,
    };
}

/// The whole device's response is the most severe any zone demands.
///
/// A device is exactly as throttled as its hottest problem: easing the compute
/// zone while the battery is in protect would be reading the wrong number.
pub fn deviceResponse(zone_responses: []const Response) Response {
    var worst: Response = .nominal;
    for (zone_responses) |response| {
        if (response.isMoreSevereThan(worst)) worst = response;
    }
    return worst;
}

/// A sensor that reports whatever a test sets.
///
/// Not a stand-in for hardware: it makes no pretence of measuring anything, and
/// reports exactly the value written to it so a test can drive policy across
/// temperatures no test rig could reach on demand. Setting `readable` to false
/// reproduces a sensor that has failed.
pub const TestSensor = struct {
    temperature: MilliCelsius = 0,
    readable: bool = true,

    pub fn sensor(test_sensor: *TestSensor) Sensor {
        return .{ .context_pointer = test_sensor, .readFn = readValue };
    }

    fn readValue(context_pointer: *anyopaque) ?MilliCelsius {
        const test_sensor: *TestSensor = @ptrCast(@alignCast(context_pointer));
        if (!test_sensor.readable) return null;
        return test_sensor.temperature;
    }
};

const reference_thresholds: Thresholds = .{
    .ease_at = 60_000,
    .throttle_at = 75_000,
    .protect_at = 90_000,
    .shut_down_at = 100_000,
    .hysteresis = 3_000,
};

test "the reference thresholds are ordered" {
    // Out-of-order thresholds would let a hotter reading pick a milder response.
    try std.testing.expect(reference_thresholds.areOrdered());
}

test "unordered thresholds are rejected" {
    var broken = reference_thresholds;
    broken.throttle_at = broken.ease_at - 1;
    try std.testing.expect(!broken.areOrdered());

    var no_margin = reference_thresholds;
    no_margin.hysteresis = 0;
    try std.testing.expect(!no_margin.areOrdered());
}

test "a rising temperature escalates through every response" {
    const readings = [_]struct { temperature: MilliCelsius, expected: Response }{
        .{ .temperature = 40_000, .expected = .nominal },
        .{ .temperature = 65_000, .expected = .ease },
        .{ .temperature = 80_000, .expected = .throttle },
        .{ .temperature = 95_000, .expected = .protect },
        .{ .temperature = 105_000, .expected = .shut_down },
    };
    var current: Response = .nominal;
    for (readings) |step| {
        current = responseFor(reference_thresholds, current, step.temperature);
        try std.testing.expectEqual(step.expected, current);
    }
}

test "a hotter reading never selects a milder response" {
    // The property the whole mechanism exists for, swept across the range.
    var temperature: MilliCelsius = 0;
    var previous: Response = .nominal;
    while (temperature <= 120_000) : (temperature += 500) {
        const response = escalate(reference_thresholds, temperature);
        try std.testing.expect(!previous.isMoreSevereThan(response));
        previous = response;
    }
}

test "a response holds until the zone cools past the hysteresis margin" {
    // Escalate to throttle, then cool to just below the threshold: the response
    // must not relax yet, or the device would flap.
    var current = responseFor(reference_thresholds, .nominal, 80_000);
    try std.testing.expectEqual(Response.throttle, current);

    current = responseFor(reference_thresholds, current, 74_000);
    try std.testing.expectEqual(Response.throttle, current);

    // Below the threshold by more than the margin, it relaxes.
    current = responseFor(reference_thresholds, current, 71_000);
    try std.testing.expectEqual(Response.ease, current);
}

test "cooling relaxes one step at a time, not straight to nominal" {
    // From protect, a reading that has dropped below the protect threshold but
    // is still hot must fall to throttle, not to nominal.
    const current = responseFor(reference_thresholds, .protect, 80_000);
    try std.testing.expectEqual(Response.throttle, current);
}

test "a sensor that cannot be read is treated as the worst" {
    var sensor: TestSensor = .{ .readable = false };
    const response = responseFor(reference_thresholds, .nominal, sensor.sensor().read());
    // A device that cannot tell how hot it is must assume the worst rather than
    // run blind.
    try std.testing.expectEqual(Response.protect, response);
}

test "the device is as throttled as its hottest zone" {
    const responses = [_]Response{ .ease, .protect, .nominal, .throttle };
    // Easing three zones while a fourth is in protect would be reading the
    // wrong number.
    try std.testing.expectEqual(Response.protect, deviceResponse(&responses));
    try std.testing.expectEqual(Response.nominal, deviceResponse(&.{ .nominal, .nominal }));
    try std.testing.expectEqual(Response.nominal, deviceResponse(&.{}));
}

test "a test sensor reports exactly what it is set to" {
    var sensor: TestSensor = .{ .temperature = 42_500 };
    try std.testing.expectEqual(@as(?MilliCelsius, 42_500), sensor.sensor().read());

    sensor.temperature = 88_000;
    try std.testing.expectEqual(@as(?MilliCelsius, 88_000), sensor.sensor().read());
}

test "the response ladder is totally ordered" {
    // A comparison must decide every pair, so that the hottest zone always wins.
    const ladder = [_]Response{ .nominal, .ease, .throttle, .protect, .shut_down };
    for (ladder, 0..) |lower, i| {
        for (ladder[i + 1 ..]) |higher| {
            try std.testing.expect(higher.isMoreSevereThan(lower));
            try std.testing.expect(!lower.isMoreSevereThan(higher));
        }
    }
}

test "each zone is a distinct heat source" {
    // The zones exist because they heat independently; a design with one number
    // for the whole device would throttle the wrong thing.
    try std.testing.expectEqual(@as(usize, 4), std.enums.values(Zone).len);
}
