//! Deciding whether a caller may read a motion sensor and at what rate, because a
//! high-rate motion stream is not the harmless data it looks like — it can infer
//! what a person types.
//!
//! Accelerometers and gyroscopes look innocuous, and on many systems they are
//! readable without any permission at all, which is exactly the problem: a fast
//! stream of motion samples taken while a person types their PIN or their message
//! carries enough signal to reconstruct the keystrokes. So a motion sensor is not
//! ungated free-for-all data. A caller in the background, where it has no
//! legitimate need for high-frequency motion, is held to a low rate that is useless
//! for keystroke inference but fine for step counting; only a foreground caller
//! that was granted high-rate access gets the fast stream. The gate is the sample
//! rate, because the rate is precisely what separates a pedometer from a keylogger.
//!
//! This module reads no sensor. It decides whether a read is permitted and caps its
//! sample rate to what the caller's grant and foreground state allow, as pure
//! functions over the request.

const std = @import("std");

/// A class of motion sensor. Grouped by what a stream from it can reveal.
pub const Sensor = enum {
    /// Linear acceleration. High-rate streams can infer taps and typing.
    accelerometer,
    /// Angular velocity. Same inference risk as the accelerometer.
    gyroscope,
    /// Ambient light, pressure, and similar slow environmental sensors. Low
    /// inference risk; still gated, but not rate-sensitive in the same way.
    environmental,
};

/// The sample rate, in hertz, above which a motion stream carries enough signal to
/// infer keystrokes. Streams for untrusted or background callers are capped below
/// this.
pub const inference_risk_hz: u32 = 50;

/// The rate a background caller is capped to: enough for step counting and
/// orientation, far below the inference threshold.
pub const background_cap_hz: u32 = 10;

/// What a caller was granted for a sensor.
pub const Grant = struct {
    /// Whether the caller may read the sensor at all.
    allowed: bool,
    /// Whether it was granted the high sample rates that carry inference risk.
    /// Without this, even a foreground caller is capped below the risk threshold.
    high_rate: bool = false,
    /// The highest rate the caller may ever receive, its own declared need.
    max_hz: u32,
};

/// A read request.
pub const Request = struct {
    sensor: Sensor,
    /// The rate the caller is asking for.
    requested_hz: u32,
    /// Whether the caller is in the foreground.
    foreground: bool,
};

/// The outcome of a sensor read request.
pub const Decision = union(enum) {
    /// The read may proceed at this capped rate — no higher than requested,
    /// granted, or the safety cap that applies.
    admit: u32,
    /// The caller holds no grant for this sensor.
    deny,

    pub fn admitted(decision: Decision) bool {
        return decision == .admit;
    }
};

/// The safety cap that applies to a request: the rate it may not exceed regardless
/// of what it asks for.
///
/// A background caller is always held below the inference threshold, whatever it
/// was granted, because there is no foreground task to justify a fast stream. A
/// foreground caller without the high-rate grant is likewise capped below the
/// threshold. Only a foreground caller with the high-rate grant may exceed it.
/// Environmental sensors are not motion sensors and carry no keystroke risk, so the
/// inference cap does not apply to them.
fn safetyCap(grant: Grant, request: Request) u32 {
    if (request.sensor == .environmental) return grant.max_hz;
    if (!request.foreground) return @min(background_cap_hz, inference_risk_hz - 1);
    if (!grant.high_rate) return inference_risk_hz - 1;
    return grant.max_hz;
}

/// Decides whether a sensor read is permitted and at what rate.
///
/// A caller with no grant is denied. Otherwise the delivered rate is the smallest
/// of what the caller asked for, what its grant allows, and the safety cap for its
/// context — so a request never exceeds the rate that separates a benign use from
/// an inference attack unless it was explicitly granted the high rate in the
/// foreground.
pub fn read(grant: Grant, request: Request) Decision {
    if (!grant.allowed) return .deny;
    const rate = @min(request.requested_hz, @min(grant.max_hz, safetyCap(grant, request)));
    return .{ .admit = rate };
}

fn makeRequest(sensor: Sensor, hz: u32, foreground: bool) Request {
    return .{ .sensor = sensor, .requested_hz = hz, .foreground = foreground };
}

test "a foreground high-rate grant gets the fast stream" {
    const grant: Grant = .{ .allowed = true, .high_rate = true, .max_hz = 200 };
    try std.testing.expectEqual(Decision{ .admit = 200 }, read(grant, makeRequest(.accelerometer, 200, true)));
}

test "a background caller is capped below the inference threshold" {
    const grant: Grant = .{ .allowed = true, .high_rate = true, .max_hz = 200 };
    const decision = read(grant, makeRequest(.accelerometer, 200, false));
    switch (decision) {
        .admit => |hz| try std.testing.expect(hz < inference_risk_hz),
        .deny => return error.TestUnexpectedResult,
    }
}

test "a foreground caller without the high-rate grant is capped below the threshold" {
    const grant: Grant = .{ .allowed = true, .high_rate = false, .max_hz = 200 };
    const decision = read(grant, makeRequest(.gyroscope, 200, true));
    switch (decision) {
        .admit => |hz| try std.testing.expect(hz < inference_risk_hz),
        .deny => return error.TestUnexpectedResult,
    }
}

test "no grant is denied" {
    const grant: Grant = .{ .allowed = false, .max_hz = 100 };
    try std.testing.expectEqual(Decision.deny, read(grant, makeRequest(.accelerometer, 100, true)));
}

test "the delivered rate never exceeds the request" {
    const grant: Grant = .{ .allowed = true, .high_rate = true, .max_hz = 200 };
    // Asking for less than the cap yields the smaller ask.
    try std.testing.expectEqual(Decision{ .admit = 20 }, read(grant, makeRequest(.accelerometer, 20, true)));
}

test "an environmental sensor is not held to the inference cap" {
    // A pressure sensor at 100 Hz carries no keystroke risk, so a foreground grant
    // serves it fully even without the high-rate flag.
    const grant: Grant = .{ .allowed = true, .high_rate = false, .max_hz = 100 };
    try std.testing.expectEqual(Decision{ .admit = 100 }, read(grant, makeRequest(.environmental, 100, true)));
}

test "no motion read ever exceeds the inference threshold without a foreground high-rate grant, swept" {
    // The keylogging-defence property: for accelerometer and gyroscope, only a
    // foreground caller with the high-rate grant is ever admitted at or above the
    // inference threshold.
    for ([_]Sensor{ .accelerometer, .gyroscope }) |sensor| {
        for ([_]bool{ false, true }) |high_rate| {
            for ([_]bool{ false, true }) |foreground| {
                const grant: Grant = .{ .allowed = true, .high_rate = high_rate, .max_hz = 500 };
                const decision = read(grant, makeRequest(sensor, 500, foreground));
                switch (decision) {
                    .admit => |hz| {
                        if (hz >= inference_risk_hz) {
                            try std.testing.expect(high_rate and foreground);
                        }
                    },
                    .deny => {},
                }
            }
        }
    }
}
