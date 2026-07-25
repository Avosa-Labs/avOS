//! The camera capture path.
//!
//! A camera is the clearest case of a sensor whose silent use is the harm, so
//! this module makes two things structurally true: a capture cannot be active
//! without its indicator lit, and two captures cannot run at once behind each
//! other's back. It decides and holds the small amount of state a capture needs
//! — which camera, whether the privacy shutter is open, whether a capture is
//! already running — and hands back a session token that only exists while a
//! capture is genuinely live.
//!
//! It drives no silicon. A real board's camera turns a session into frames; this
//! is the policy every board shares, so the rule that a live capture lights the
//! light holds the same way on every one of them.

const std = @import("std");

/// Which camera. The privacy question — "is a camera watching" — is the same for
/// both, but a session names which so the right indicator lights.
pub const Facing = enum { front, back };

/// Why a capture was refused.
pub const Refusal = enum {
    /// A capture is already running; a second cannot start behind it.
    already_active,
    /// The privacy shutter is closed. A closed shutter is a physical "no" that a
    /// capability does not override.
    shutter_closed,
    /// No indicator is available to light, so a capture could run unseen. Fail
    /// closed rather than capture without the light.
    no_indicator,

    pub fn describe(refusal: Refusal) []const u8 {
        return switch (refusal) {
            .already_active => "a capture is already running",
            .shutter_closed => "the privacy shutter is closed",
            .no_indicator => "no capture indicator is available",
        };
    }
};

/// Proof that a capture is live and its indicator is lit.
///
/// It cannot be constructed by naming its fields — the witness type is private —
/// so the only way to hold one is `Camera.begin`, which lights the indicator
/// first. A path that has a `Session` has already lit the light, and the light
/// stays lit until the session is ended.
pub const Session = struct {
    facing: Facing,
    witness: Witness,

    const Witness = struct {};
};

pub const Outcome = union(enum) {
    started: Session,
    refused: Refusal,

    pub fn isStarted(outcome: Outcome) bool {
        return outcome == .started;
    }
};

/// One camera subsystem and the state a capture needs.
pub const Camera = struct {
    /// Whether the privacy shutter is open. A closed shutter refuses capture
    /// regardless of authority.
    shutter_open: bool = true,
    /// Whether an indicator exists to light. A device with no way to show
    /// capture must not capture.
    indicator_present: bool = true,
    /// The facing of the running capture, or null when idle.
    active: ?Facing = null,
    /// Whether the indicator is lit. Set only by starting a capture, cleared only
    /// by ending it, so it tracks capture exactly.
    indicator_lit: bool = false,

    /// Starts a capture, lighting the indicator, or refuses with a reason.
    ///
    /// A capture starts only when none is running, the shutter is open, and an
    /// indicator can be lit; starting lights it and returns the session that
    /// stands for the live capture.
    pub fn begin(camera: *Camera, facing: Facing) Outcome {
        if (camera.active != null) return .{ .refused = .already_active };
        if (!camera.shutter_open) return .{ .refused = .shutter_closed };
        if (!camera.indicator_present) return .{ .refused = .no_indicator };

        camera.active = facing;
        camera.indicator_lit = true;
        return .{ .started = .{ .facing = facing, .witness = .{} } };
    }

    /// Ends the running capture and turns the indicator off. Ending an idle
    /// camera is a no-op, so a duplicated stop is harmless.
    pub fn end(camera: *Camera, session: Session) void {
        if (camera.active) |facing| {
            if (facing == session.facing) {
                camera.active = null;
                camera.indicator_lit = false;
            }
        }
    }

    /// Closes the privacy shutter. A running capture is stopped and its light
    /// cleared: the shutter is a hard "no", not a preference.
    pub fn closeShutter(camera: *Camera) void {
        camera.shutter_open = false;
        camera.active = null;
        camera.indicator_lit = false;
    }

    pub fn openShutter(camera: *Camera) void {
        camera.shutter_open = true;
    }

    /// The invariant every caller relies on: the indicator is lit exactly when a
    /// capture is active. Nothing can put the camera in any other state.
    pub fn indicatorMatchesCapture(camera: Camera) bool {
        return camera.indicator_lit == (camera.active != null);
    }
};

const testing = std.testing;

test "a capture lights the indicator and a session stands for it" {
    var camera: Camera = .{};
    const outcome = camera.begin(.back);
    try testing.expect(outcome.isStarted());
    try testing.expect(camera.indicator_lit);
    try testing.expect(camera.indicatorMatchesCapture());

    camera.end(outcome.started);
    try testing.expect(!camera.indicator_lit);
    try testing.expect(camera.indicatorMatchesCapture());
}

test "a second capture cannot start behind the first" {
    var camera: Camera = .{};
    _ = camera.begin(.back);
    const second = camera.begin(.front);
    try testing.expect(!second.isStarted());
    try testing.expectEqual(Refusal.already_active, second.refused);
}

test "a closed shutter refuses capture and stops a running one" {
    var camera: Camera = .{ .shutter_open = false };
    try testing.expectEqual(Refusal.shutter_closed, camera.begin(.back).refused);

    camera.openShutter();
    const running = camera.begin(.back);
    try testing.expect(running.isStarted());

    // Closing the shutter mid-capture stops it and clears the light.
    camera.closeShutter();
    try testing.expect(camera.active == null);
    try testing.expect(!camera.indicator_lit);
    try testing.expect(camera.indicatorMatchesCapture());
}

test "a device with no indicator refuses to capture" {
    var camera: Camera = .{ .indicator_present = false };
    try testing.expectEqual(Refusal.no_indicator, camera.begin(.front).refused);
    try testing.expect(!camera.indicator_lit);
}
