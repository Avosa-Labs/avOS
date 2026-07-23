//! The passive sensors, and why a reading from one is never handed out raw.
//!
//! Motion, orientation, and ambient light look harmless — a step counter, an
//! auto-rotate, a brightness curve. They are not. A high-rate accelerometer
//! stream reconstructs what a person typed, where they walked, and whether they
//! are asleep, and it does so without the capture indicator a camera would show.
//! So a sensor reading is gated like any other device access and, beyond that,
//! rate-limited: the difference between a sensor that tells the display the room
//! is dim and one that fingerprints a person's gait is how often it is sampled.
//!
//! This module holds the sample-rate policy and the reading types. It reads no
//! hardware; a board's sensors deliver samples through the interface, and this
//! decides the fastest rate a given use is allowed to pull them at. The policy
//! is logic, testable across rates a physical sensor would have to actually run
//! to exercise.

const std = @import("std");

/// The passive sensor kinds.
pub const Kind = enum {
    /// Linear acceleration. The most revealing: at a high rate it reconstructs
    /// keystrokes and gait.
    accelerometer,
    /// Rotation rate. Similar reach to the accelerometer.
    gyroscope,
    /// Device orientation relative to magnetic north.
    magnetometer,
    /// Ambient light in lux. Low-bandwidth and low-risk, but still gated so the
    /// rule that everything is gated has no exceptions.
    ambient_light,
    /// Whether something is near the screen, for turning it off during a call.
    proximity,

    /// The highest sample rate this kind may ever be driven at, in hertz.
    ///
    /// A ceiling per kind, because the risk is a property of the sensor: no use,
    /// however privileged, pulls an accelerometer fast enough to reconstruct
    /// keystrokes, while a light sensor has little to reveal at any rate.
    pub fn maxHertz(kind: Kind) u16 {
        return switch (kind) {
            .accelerometer, .gyroscope => 200,
            .magnetometer => 50,
            .ambient_light, .proximity => 10,
        };
    }

    /// Whether a high-rate stream of this kind can reveal what a person is
    /// doing, rather than merely a coarse device state.
    pub fn isHighBandwidthPersonalRisk(kind: Kind) bool {
        return kind == .accelerometer or kind == .gyroscope;
    }
};

/// What a sensor reading is used for, which bounds how fast it may be sampled.
///
/// The same accelerometer feeds a step counter and a game. The step counter
/// needs a few samples a second; the game needs many. The use, not the sensor,
/// decides which — but never above the sensor's own ceiling.
pub const Use = enum {
    /// Deciding a coarse device state: orientation, is-it-dark, is-it-at-an-ear.
    /// A slow rate is plenty.
    device_state,
    /// Counting steps or detecting a pickup. Needs a modest rate.
    activity,
    /// Driving an interaction in real time: a game, a level. Needs the fastest
    /// rate the use and sensor together allow.
    interactive,

    /// The sample rate this use asks for, in hertz.
    pub fn requestedHertz(use: Use) u16 {
        return switch (use) {
            .device_state => 5,
            .activity => 25,
            .interactive => 120,
        };
    }
};

/// A single reading, in whatever units the kind reports.
///
/// Three axes because the motion sensors are three-dimensional; single-value
/// sensors use the first axis and leave the rest zero, which is simpler than a
/// union and costs three integers.
pub const Reading = struct {
    kind: Kind,
    /// Values in the kind's native milli-units: milli-g, milli-degrees per
    /// second, milli-lux. Integer so a reading compares identically everywhere.
    axis: [3]i32,
    /// When the sample was taken, in milliseconds on the device clock.
    at_ms: u64,
};

/// The rate a use may sample a kind at.
///
/// The lower of what the use asks for and what the kind allows. A use never
/// pulls a sensor faster than the sensor's ceiling, whatever it requests, so the
/// personal-risk ceiling on the accelerometer cannot be raised by claiming an
/// interactive use.
pub fn permittedHertz(kind: Kind, use: Use) u16 {
    return @min(use.requestedHertz(), kind.maxHertz());
}

/// Whether a requested rate is allowed for a use of a kind.
pub fn allows(kind: Kind, use: Use, requested_hertz: u16) bool {
    return requested_hertz <= permittedHertz(kind, use);
}

/// A source of sensor readings.
///
/// An interface, because a sample is a hardware fact. On a board this is the
/// sensor; in a test it is a value a test sets. Nothing here fabricates a
/// plausible reading on a host without a sensor.
pub const Source = struct {
    context_pointer: *anyopaque,
    readFn: *const fn (context_pointer: *anyopaque, kind: Kind) ?Reading,

    pub fn read(source: Source, kind: Kind) ?Reading {
        return source.readFn(source.context_pointer, kind);
    }
};

/// A sensor source that reports whatever a test sets.
///
/// Measures nothing; reports the reading written to it so a test can drive the
/// rate policy and the consumers of readings without a physical sensor.
pub const TestSource = struct {
    reading: ?Reading = null,

    pub fn source(test_source: *TestSource) Source {
        return .{ .context_pointer = test_source, .readFn = readValue };
    }

    fn readValue(context_pointer: *anyopaque, kind: Kind) ?Reading {
        const test_source: *TestSource = @ptrCast(@alignCast(context_pointer));
        const reading = test_source.reading orelse return null;
        // A source reports for its configured kind only; asking for another
        // returns nothing, matching a board where each sensor is its own source.
        if (reading.kind != kind) return null;
        return reading;
    }
};

test "a use never samples a sensor above the sensor's ceiling" {
    // An interactive use asks for 120 Hz, but the accelerometer's personal-risk
    // ceiling is 200 — here it is allowed. The magnetometer's ceiling is 50, so
    // the same interactive use is capped there.
    try std.testing.expectEqual(@as(u16, 120), permittedHertz(.accelerometer, .interactive));
    try std.testing.expectEqual(@as(u16, 50), permittedHertz(.magnetometer, .interactive));
}

test "the sensor ceiling cannot be raised by claiming a faster use" {
    // Whatever use is claimed, a light sensor tops out at 10 Hz.
    for (std.enums.values(Use)) |use| {
        try std.testing.expect(permittedHertz(.ambient_light, use) <= Kind.ambient_light.maxHertz());
    }
}

test "a slow use gets a slow rate even on a fast sensor" {
    // Device-state use asks for 5 Hz; it gets 5 even from an accelerometer that
    // could go to 200, because the use does not need more and the extra is only
    // more revealing.
    try std.testing.expectEqual(@as(u16, 5), permittedHertz(.accelerometer, .device_state));
}

test "a request within the permitted rate is allowed and above it is not" {
    try std.testing.expect(allows(.accelerometer, .interactive, 100));
    try std.testing.expect(allows(.accelerometer, .interactive, 120));
    try std.testing.expect(!allows(.accelerometer, .interactive, 121));
    try std.testing.expect(!allows(.ambient_light, .interactive, 20));
}

test "the motion sensors are the high-bandwidth personal risk" {
    try std.testing.expect(Kind.accelerometer.isHighBandwidthPersonalRisk());
    try std.testing.expect(Kind.gyroscope.isHighBandwidthPersonalRisk());
    try std.testing.expect(!Kind.ambient_light.isHighBandwidthPersonalRisk());
    try std.testing.expect(!Kind.proximity.isHighBandwidthPersonalRisk());
}

test "every kind has a ceiling and every use a request" {
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(kind.maxHertz() > 0);
    }
    for (std.enums.values(Use)) |use| {
        try std.testing.expect(use.requestedHertz() > 0);
    }
}

test "a test source reports only for its configured kind" {
    var source: TestSource = .{ .reading = .{
        .kind = .accelerometer,
        .axis = .{ 100, -50, 980 },
        .at_ms = 1_000,
    } };
    const interface = source.source();

    // Its own kind returns the reading; another kind returns nothing, matching a
    // board where each sensor is a separate source.
    try std.testing.expect(interface.read(.accelerometer) != null);
    try std.testing.expect(interface.read(.gyroscope) == null);
}

test "a source that has no reading returns null" {
    var source: TestSource = .{};
    try std.testing.expect(source.source().read(.ambient_light) == null);
}

test "the highest permitted rate belongs to the highest-risk sensor" {
    // The accelerometer and gyroscope carry the highest ceiling precisely
    // because the policy is per-sensor, and their reach is what makes the
    // per-use limiting matter.
    try std.testing.expect(
        Kind.accelerometer.maxHertz() >= Kind.ambient_light.maxHertz(),
    );
}
