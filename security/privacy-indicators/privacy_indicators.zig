//! The indicator a person sees when the camera, microphone, or location is in
//! use, and the rule that nothing can turn it off while the sensor is on.
//!
//! A recording indicator is only worth anything if it cannot lie. The whole
//! value of the light that says "the camera is on" is that a person can trust
//! it: if any software could keep the camera active while the light is off, the
//! light would mean nothing and a person could be watched believing they were
//! not. So the indicator is not a thing software asks to show. It is a function
//! of whether a sensor is active, computed here, and it lights whenever the
//! sensor does and stays lit for a moment after, never the other way around.
//!
//! This module owns that computation. It holds which sensors are active, decides
//! what the indicator shows, and enforces the two properties that make it
//! trustworthy: an active sensor always shows its indicator, and the indicator
//! lingers briefly after the sensor stops so a recording too short to notice is
//! still seen. It draws nothing; the surface reads this state and must render it
//! where a person cannot miss it.

const std = @import("std");

/// The sensors whose use a person must be shown.
///
/// The capture and location sensors, because using them silently is the harm.
/// A sensor not on this list is not one whose use needs an indicator, which is a
/// deliberate boundary: adding one here is adding a promise to show it.
pub const Sensor = enum {
    camera,
    microphone,
    location,

    pub const count = std.enums.values(Sensor).len;

    /// How the indicator for this sensor reads, so a person can tell a camera
    /// from a microphone at a glance.
    pub fn indicatorColor(sensor: Sensor) []const u8 {
        return switch (sensor) {
            .camera, .microphone => "green",
            .location => "blue",
        };
    }
};

/// How long the indicator stays lit after a sensor stops, in milliseconds.
///
/// A brief lingering, so a recording too short to see live still leaves a mark a
/// person can catch. Without it, software could strobe a sensor on and off fast
/// enough that the indicator never appears to a human eye.
pub const linger_ms: u64 = 500;

/// What the indicator must show for one sensor.
pub const Indicator = struct {
    sensor: Sensor,
    /// True while the sensor is active or within the linger window after it
    /// stopped.
    lit: bool,
    /// True only while the sensor is actually active now, so a surface can show
    /// a solid versus a fading indicator if it chooses.
    actively_recording: bool,
};

/// The state of every sensor's indicator.
///
/// One entry per sensor, always present, because an indicator that could be
/// absent is an indicator that could be missing when it matters. The state is
/// computed from when each sensor last started and stopped, never set directly,
/// so no code path can assert "off" while a sensor is on.
pub const State = struct {
    /// When each sensor became active, or null if it is not active.
    active_since_ms: [Sensor.count]?u64 = @splat(null),
    /// When each sensor last stopped, for the linger window.
    stopped_at_ms: [Sensor.count]?u64 = @splat(null),

    /// Records that a sensor started.
    pub fn sensorStarted(state: *State, sensor: Sensor, now_ms: u64) void {
        state.active_since_ms[@intFromEnum(sensor)] = now_ms;
        state.stopped_at_ms[@intFromEnum(sensor)] = null;
    }

    /// Records that a sensor stopped. The indicator lingers from here.
    pub fn sensorStopped(state: *State, sensor: Sensor, now_ms: u64) void {
        state.active_since_ms[@intFromEnum(sensor)] = null;
        state.stopped_at_ms[@intFromEnum(sensor)] = now_ms;
    }

    /// The indicator for one sensor as of now.
    ///
    /// Lit if the sensor is active, or if it stopped within the linger window.
    /// There is no argument by which this returns unlit for an active sensor —
    /// that is the property the whole module exists to hold.
    pub fn indicatorFor(state: State, sensor: Sensor, now_ms: u64) Indicator {
        const index = @intFromEnum(sensor);
        const active = state.active_since_ms[index] != null;
        const lingering = if (active) false else within: {
            const stopped = state.stopped_at_ms[index] orelse break :within false;
            break :within now_ms >= stopped and now_ms - stopped < linger_ms;
        };
        return .{
            .sensor = sensor,
            .lit = active or lingering,
            .actively_recording = active,
        };
    }

    /// Whether any indicator is lit right now.
    ///
    /// A surface uses this to decide whether to reserve the indicator area at
    /// all, but must compute each indicator individually to render it — this is
    /// a shortcut, not the source of truth.
    pub fn anyLit(state: State, now_ms: u64) bool {
        for (std.enums.values(Sensor)) |sensor| {
            if (state.indicatorFor(sensor, now_ms).lit) return true;
        }
        return false;
    }

    /// Whether a sensor is actively recording right now, ignoring the linger.
    ///
    /// For a caller that needs the true current sensor state rather than what the
    /// indicator shows. This is the present state, not a query about a past
    /// moment: a sensor that has stopped is not active, however recently.
    pub fn isActive(state: State, sensor: Sensor) bool {
        return state.active_since_ms[@intFromEnum(sensor)] != null;
    }
};

test "an active sensor always shows its indicator" {
    // The core property: there is no time at which an active sensor is unlit.
    var state: State = .{};
    state.sensorStarted(.camera, 1_000);

    // At the moment it starts, and at every later moment while active.
    for ([_]u64{ 1_000, 1_001, 5_000, 1_000_000 }) |now| {
        const indicator = state.indicatorFor(.camera, now);
        try std.testing.expect(indicator.lit);
        try std.testing.expect(indicator.actively_recording);
    }
}

test "the indicator lingers after the sensor stops" {
    var state: State = .{};
    state.sensorStarted(.microphone, 1_000);
    state.sensorStopped(.microphone, 2_000);

    // Just after stopping, still lit — but no longer actively recording.
    const during = state.indicatorFor(.microphone, 2_100);
    try std.testing.expect(during.lit);
    try std.testing.expect(!during.actively_recording);

    // After the linger window, unlit.
    const after = state.indicatorFor(.microphone, 2_000 + linger_ms);
    try std.testing.expect(!after.lit);
}

test "a recording too short to notice still leaves a mark" {
    // Started and stopped in the same instant: the linger guarantees it is still
    // visible for the window, so strobing a sensor cannot hide it.
    var state: State = .{};
    state.sensorStarted(.camera, 5_000);
    state.sensorStopped(.camera, 5_000);

    try std.testing.expect(state.indicatorFor(.camera, 5_000).lit);
    try std.testing.expect(state.indicatorFor(.camera, 5_000 + linger_ms - 1).lit);
    try std.testing.expect(!state.indicatorFor(.camera, 5_000 + linger_ms).lit);
}

test "each sensor's indicator is independent" {
    var state: State = .{};
    state.sensorStarted(.camera, 1_000);
    // Microphone never started: its indicator is unlit while the camera's is
    // lit.
    try std.testing.expect(state.indicatorFor(.camera, 1_500).lit);
    try std.testing.expect(!state.indicatorFor(.microphone, 1_500).lit);
}

test "restarting a sensor within the linger keeps it actively recording" {
    var state: State = .{};
    state.sensorStarted(.location, 1_000);
    state.sensorStopped(.location, 1_100);
    // It restarts before the linger expires.
    state.sensorStarted(.location, 1_200);

    const indicator = state.indicatorFor(.location, 1_300);
    try std.testing.expect(indicator.lit);
    // It is active again, not merely lingering.
    try std.testing.expect(indicator.actively_recording);
}

test "any-lit reflects the individual indicators" {
    var state: State = .{};
    try std.testing.expect(!state.anyLit(1_000));
    state.sensorStarted(.camera, 1_000);
    try std.testing.expect(state.anyLit(1_000));
    state.sensorStopped(.camera, 1_100);
    // Lingering still counts as lit.
    try std.testing.expect(state.anyLit(1_200));
    try std.testing.expect(!state.anyLit(1_100 + linger_ms));
}

test "the true sensor state ignores the linger" {
    var state: State = .{};
    state.sensorStarted(.camera, 1_000);
    state.sensorStopped(.camera, 1_100);
    // The indicator still shows lit during the linger, but the sensor is not
    // active now — a caller can tell the difference.
    try std.testing.expect(state.indicatorFor(.camera, 1_200).lit);
    try std.testing.expect(!state.isActive(.camera));

    // While the sensor is genuinely active, isActive reports true.
    var running: State = .{};
    running.sensorStarted(.camera, 1_000);
    try std.testing.expect(running.isActive(.camera));
}

test "the capture and location sensors are the ones with indicators" {
    // A deliberate, closed set: exactly camera, microphone, location.
    try std.testing.expectEqual(@as(usize, 3), Sensor.count);
    for (std.enums.values(Sensor)) |sensor| {
        try std.testing.expect(sensor.indicatorColor().len > 0);
    }
}

test "camera and microphone share a color distinct from location" {
    try std.testing.expectEqualStrings("green", Sensor.camera.indicatorColor());
    try std.testing.expectEqualStrings("green", Sensor.microphone.indicatorColor());
    try std.testing.expectEqualStrings("blue", Sensor.location.indicatorColor());
}

test "a sensor active from the start of time is lit at time zero" {
    // Guards the linger arithmetic against underflow near zero.
    var state: State = .{};
    state.sensorStarted(.camera, 0);
    try std.testing.expect(state.indicatorFor(.camera, 0).lit);
    state.sensorStopped(.camera, 0);
    try std.testing.expect(state.indicatorFor(.camera, 0).lit);
    try std.testing.expect(!state.indicatorFor(.camera, linger_ms).lit);
}
