//! Routing audio to the right place, and bounding how loud it may get.
//!
//! Loud audio is the one output on a phone that can injure a person directly and
//! permanently. Sustained high volume into headphones damages hearing, and the
//! danger is worse precisely because it does not hurt at the moment it does the
//! harm. So output volume is not whatever a caller sets; it is bounded by where
//! the audio is going — a speaker across a room and an earbud pressed into an ear
//! are not the same risk — and by how long it has already been loud. This module
//! makes that bounding decision.
//!
//! It drives no codec and moves no samples. It takes the current output route
//! and a requested volume and returns the volume that may actually be played,
//! plus where it goes. The routing rules and the loudness limit are logic,
//! testable across durations and levels a listener would have to actually endure
//! to reproduce.

const std = @import("std");

/// Volume as a fraction of the output's maximum, in hundredths of a percent.
pub const VolumeBasisPoints = u16;

pub const full_volume: VolumeBasisPoints = 10_000;

/// Where audio is going.
///
/// The route is a safety input, not just a preference, because the same volume
/// is harmless from a speaker and dangerous in an ear.
pub const Route = enum {
    /// The built-in speaker. Held away from the ear; the loudness limit is
    /// higher because the sound disperses.
    speaker,
    /// The earpiece, for a call held to the head.
    earpiece,
    /// Wired headphones or earbuds. Pressed into the ear; the strictest limit.
    wired_headset,
    /// Bluetooth headphones. Same ear proximity, same strict limit.
    wireless_headset,
    /// An external device over a cable or cast. Its own amplifier governs
    /// loudness, so this device does not additionally limit it.
    external,

    /// Whether audio on this route reaches an ear closely enough to risk
    /// hearing damage at high volume.
    pub fn isNearEar(route: Route) bool {
        return switch (route) {
            .earpiece, .wired_headset, .wireless_headset => true,
            .speaker, .external => false,
        };
    }
};

/// Why a requested volume was changed.
pub const Adjustment = enum {
    /// Played as asked.
    unchanged,
    /// Lowered to the route's loudness ceiling.
    capped_for_route,
    /// Lowered because it has been loud for long enough to risk harm, until the
    /// person confirms they want to continue.
    reduced_for_exposure,

    pub fn wasLimited(adjustment: Adjustment) bool {
        return adjustment != .unchanged;
    }
};

/// The loudness limits.
pub const Limits = struct {
    /// The highest volume a near-ear route may reach without confirmation.
    near_ear_ceiling: VolumeBasisPoints,
    /// The volume above which time spent counts toward the exposure limit.
    loud_above: VolumeBasisPoints,
    /// How long a near-ear route may stay loud before it is reduced pending
    /// confirmation, in seconds.
    max_loud_seconds: u32,
    /// The safe volume it is reduced to.
    safe_volume: VolumeBasisPoints,

    pub fn areValid(limits: Limits) bool {
        return limits.near_ear_ceiling <= full_volume and
            limits.loud_above < limits.near_ear_ceiling and
            limits.safe_volume <= limits.loud_above and
            limits.max_loud_seconds > 0;
    }

    /// A reference set roughly matching hearing-safety guidance: near-ear routes
    /// capped below full, loud counted above ~60%, reduced after an hour.
    pub const reference: Limits = .{
        .near_ear_ceiling = 8_500,
        .loud_above = 6_000,
        .max_loud_seconds = 3_600,
        .safe_volume = 5_000,
    };
};

/// What the output should be set to.
pub const Command = struct {
    volume: VolumeBasisPoints,
    route: Route,
    adjustment: Adjustment,
};

/// Decides the playable volume for a request.
///
/// `loud_seconds` is how long this route has already been above the loud
/// threshold; the caller accumulates it, because whether more loudness is a risk
/// depends on the exposure so far. The exposure reduction wins over the route
/// cap when both apply, because it is the more urgent of the two: a route cap
/// prevents reaching a dangerous level, and an exposure reduction responds to
/// having been at one.
pub fn decide(
    limits: Limits,
    route: Route,
    requested: VolumeBasisPoints,
    loud_seconds: u32,
) Command {
    // An external route governs its own loudness through its own amplifier, so
    // this device passes the request through unchanged.
    if (!route.isNearEar() and route != .speaker) {
        return .{ .volume = requested, .route = route, .adjustment = .unchanged };
    }

    // The speaker disperses sound, so it is only capped at full, never for the
    // ear.
    if (!route.isNearEar()) {
        const volume = @min(requested, full_volume);
        return .{
            .volume = volume,
            .route = route,
            .adjustment = if (volume < requested) .capped_for_route else .unchanged,
        };
    }

    // Near-ear: exposure first. Having been loud too long, the volume is reduced
    // to safe until the person confirms, whatever they requested.
    if (loud_seconds >= limits.max_loud_seconds and requested > limits.safe_volume) {
        return .{
            .volume = limits.safe_volume,
            .route = route,
            .adjustment = .reduced_for_exposure,
        };
    }

    // Then the route ceiling: a near-ear route never reaches full without a
    // deliberate confirmation this policy does not grant on its own.
    if (requested > limits.near_ear_ceiling) {
        return .{
            .volume = limits.near_ear_ceiling,
            .route = route,
            .adjustment = .capped_for_route,
        };
    }

    return .{ .volume = requested, .route = route, .adjustment = .unchanged };
}

// --- Microphone capture ---
//
// Output governs how loud sound may be; capture governs whether the device may
// listen, which is the privacy question. A live capture lights an indicator a
// person can see and a hardware mute is a hard no, mirrored on the same rules
// the camera capture path uses so listening cannot happen unseen or through a
// mute.

pub const CaptureRefusal = enum {
    /// A capture is already running.
    already_active,
    /// The microphone is muted in hardware. A capability does not override it.
    muted,
    /// No indicator is available to show that the device is listening.
    no_indicator,

    pub fn describe(refusal: CaptureRefusal) []const u8 {
        return switch (refusal) {
            .already_active => "a capture is already running",
            .muted => "the microphone is muted",
            .no_indicator => "no capture indicator is available",
        };
    }
};

/// Proof that a microphone capture is live and its indicator lit. Constructed
/// only by `Microphone.begin`, which lights the indicator, so holding one means
/// the light is on.
pub const CaptureSession = struct {
    witness: Witness,
    const Witness = struct {};
};

pub const CaptureOutcome = union(enum) {
    started: CaptureSession,
    refused: CaptureRefusal,

    pub fn isStarted(outcome: CaptureOutcome) bool {
        return outcome == .started;
    }
};

pub const Microphone = struct {
    /// A hardware mute the running system cannot override.
    muted: bool = false,
    /// Whether an indicator exists to show listening.
    indicator_present: bool = true,
    /// Whether a capture is running.
    active: bool = false,
    /// Lit exactly while a capture is active.
    indicator_lit: bool = false,

    /// Starts listening, lighting the indicator, or refuses with a reason.
    pub fn begin(microphone: *Microphone) CaptureOutcome {
        if (microphone.active) return .{ .refused = .already_active };
        if (microphone.muted) return .{ .refused = .muted };
        if (!microphone.indicator_present) return .{ .refused = .no_indicator };

        microphone.active = true;
        microphone.indicator_lit = true;
        return .{ .started = .{ .witness = .{} } };
    }

    /// Stops listening and clears the indicator. A duplicated stop is harmless.
    pub fn end(microphone: *Microphone, session: CaptureSession) void {
        _ = session;
        microphone.active = false;
        microphone.indicator_lit = false;
    }

    /// Mutes in hardware, stopping any running capture and clearing its light.
    pub fn mute(microphone: *Microphone) void {
        microphone.muted = true;
        microphone.active = false;
        microphone.indicator_lit = false;
    }

    pub fn unmute(microphone: *Microphone) void {
        microphone.muted = false;
    }

    /// The invariant: the indicator is lit exactly when a capture is active.
    pub fn indicatorMatchesCapture(microphone: Microphone) bool {
        return microphone.indicator_lit == microphone.active;
    }
};

const reference = Limits.reference;

test "a microphone capture lights the indicator and stops cleanly" {
    var microphone: Microphone = .{};
    const outcome = microphone.begin();
    try std.testing.expect(outcome.isStarted());
    try std.testing.expect(microphone.indicator_lit);
    try std.testing.expect(microphone.indicatorMatchesCapture());

    microphone.end(outcome.started);
    try std.testing.expect(!microphone.indicator_lit);
    try std.testing.expect(microphone.indicatorMatchesCapture());
}

test "a muted microphone refuses capture and mute stops a running one" {
    var microphone: Microphone = .{};
    _ = microphone.begin();
    microphone.mute();
    try std.testing.expect(!microphone.active);
    try std.testing.expect(!microphone.indicator_lit);
    try std.testing.expectEqual(CaptureRefusal.muted, microphone.begin().refused);
}

test "a second microphone capture cannot start behind the first" {
    var microphone: Microphone = .{};
    _ = microphone.begin();
    try std.testing.expectEqual(CaptureRefusal.already_active, microphone.begin().refused);
}

test "a microphone with no indicator refuses to listen" {
    var microphone: Microphone = .{ .indicator_present = false };
    try std.testing.expectEqual(CaptureRefusal.no_indicator, microphone.begin().refused);
}

test "the reference limits are valid" {
    try std.testing.expect(reference.areValid());
}

test "inconsistent limits are rejected" {
    var bad = reference;
    bad.safe_volume = reference.loud_above + 1;
    try std.testing.expect(!bad.areValid());
}

test "the speaker is not capped for the ear" {
    const command = decide(reference, .speaker, full_volume, 0);
    try std.testing.expectEqual(Adjustment.unchanged, command.adjustment);
    try std.testing.expectEqual(full_volume, command.volume);
}

test "a near-ear route is capped below full" {
    const command = decide(reference, .wired_headset, full_volume, 0);
    try std.testing.expectEqual(Adjustment.capped_for_route, command.adjustment);
    try std.testing.expectEqual(reference.near_ear_ceiling, command.volume);
    try std.testing.expect(command.volume < full_volume);
}

test "both headset routes are held to the same ceiling" {
    for ([_]Route{ .wired_headset, .wireless_headset }) |route| {
        const command = decide(reference, route, full_volume, 0);
        try std.testing.expectEqual(reference.near_ear_ceiling, command.volume);
    }
}

test "prolonged loud audio is reduced pending confirmation" {
    // Loud for the full exposure window: reduced to safe whatever is requested.
    const command = decide(reference, .wired_headset, reference.near_ear_ceiling, reference.max_loud_seconds);
    try std.testing.expectEqual(Adjustment.reduced_for_exposure, command.adjustment);
    try std.testing.expectEqual(reference.safe_volume, command.volume);
}

test "exposure reduction outranks the route cap" {
    // Both would apply; the exposure reduction is the more urgent and wins,
    // giving the safe volume rather than the higher route ceiling.
    const command = decide(reference, .wireless_headset, full_volume, reference.max_loud_seconds);
    try std.testing.expectEqual(Adjustment.reduced_for_exposure, command.adjustment);
    try std.testing.expectEqual(reference.safe_volume, command.volume);
}

test "a quiet near-ear request is untouched" {
    const command = decide(reference, .wired_headset, 3_000, 0);
    try std.testing.expectEqual(Adjustment.unchanged, command.adjustment);
    try std.testing.expectEqual(@as(VolumeBasisPoints, 3_000), command.volume);
}

test "an external route governs its own loudness" {
    // Its own amplifier is responsible; this device does not add a limit.
    const command = decide(reference, .external, full_volume, reference.max_loud_seconds);
    try std.testing.expectEqual(Adjustment.unchanged, command.adjustment);
    try std.testing.expectEqual(full_volume, command.volume);
}

test "no near-ear volume ever exceeds the ceiling without exposure" {
    // Swept: below the exposure window, a near-ear route is always at or under
    // the ceiling.
    var requested: VolumeBasisPoints = 0;
    while (requested <= full_volume) : (requested += 100) {
        const command = decide(reference, .wired_headset, requested, 0);
        try std.testing.expect(command.volume <= reference.near_ear_ceiling);
    }
}

test "only the near-ear routes are treated as an ear risk" {
    try std.testing.expect(Route.earpiece.isNearEar());
    try std.testing.expect(Route.wired_headset.isNearEar());
    try std.testing.expect(Route.wireless_headset.isNearEar());
    try std.testing.expect(!Route.speaker.isNearEar());
    try std.testing.expect(!Route.external.isNearEar());
}

test "the earpiece is bounded like a headset" {
    // A call held to the head is as close to the ear as an earbud.
    const command = decide(reference, .earpiece, full_volume, 0);
    try std.testing.expect(command.volume <= reference.near_ear_ceiling);
}
