//! Which principal may reach which device, and under what condition.
//!
//! A device is not reached by holding a pointer to it. It is reached by holding
//! a capability the control plane issued, and this module is where the kernel
//! decides whether a given reach is one that capability actually authorizes for
//! that device, right now. It touches no hardware; it answers a yes-or-no
//! question about an attempt, as a pure function, so the answer is testable
//! without a device present.
//!
//! The device classes here are the ones whose access a person cares about
//! because reaching them is felt: a camera that turns on, a microphone that
//! listens, a radio that transmits, a location that is read. For those, access
//! is never ambient. The most privileged software on the device still presents
//! a capability, and some — the ones that are a safety matter rather than a
//! convenience — additionally require that a person is present to have allowed
//! it.

const std = @import("std");

/// The device classes access is decided for.
///
/// Grouped by what reaching them means to a person, not by the bus they sit on.
/// Two cameras are one class here because the question "may this principal use a
/// camera" is the same question for both.
pub const DeviceClass = enum {
    /// Sees. A capture indicator must be lit whenever it is active.
    camera,
    /// Hears. Same indicator rule.
    microphone,
    /// Knows where the device is.
    location,
    /// Transmits: cellular, wireless, near-field. Reaching outward.
    radio,
    /// Reads the person's body: fingerprint, face, heart rate.
    biometric,
    /// Moves something in the world: a motor, an actuator, a lock. The class
    /// that can cause physical harm.
    actuator,
    /// Reports orientation, motion, light. Passive, but still gated because a
    /// motion trace reveals more than it appears to.
    sensor,
    /// Draws to a screen and drives haptics. The least sensitive class, gated
    /// so that the rule "everything presents a capability" has no exceptions.
    display,

    /// Whether using this class lights a capture indicator a person can see.
    ///
    /// A camera or microphone that could be used without the light is a camera
    /// or microphone that can watch or listen unnoticed, which is the single
    /// property this class of device must never have.
    pub fn showsCaptureIndicator(class: DeviceClass) bool {
        return class == .camera or class == .microphone;
    }

    /// Whether reaching this class can cause physical harm.
    ///
    /// An actuator moves something. Access to it is held to the strictest bar
    /// because the failure is not a privacy loss but an injury.
    pub fn isPhysicallyConsequential(class: DeviceClass) bool {
        return class == .actuator;
    }
};

/// What is being attempted on a device.
pub const Access = enum {
    /// Read a value, a frame, a sample.
    read,
    /// Start a stream: keep capturing or keep transmitting.
    stream,
    /// Change the world: move, lock, transmit an outward message.
    actuate,
    /// Change how the device is configured.
    configure,

    /// Whether this access, on a capture-capable device, activates the sensor.
    ///
    /// Configuration does not, so setting a camera's resolution while it is off
    /// must not light the indicator, and starting a stream must.
    pub fn activatesSensor(access: Access) bool {
        return access == .read or access == .stream;
    }
};

/// What the kernel knows about the moment an access is attempted.
pub const Situation = struct {
    /// Whether a person is present and has authenticated recently. Required for
    /// the classes whose misuse a person could not otherwise notice or prevent.
    person_present: bool = false,
    /// Whether the device is in a state that permits physical action at all —
    /// not locked, not in a safety hold. An actuator obeys this even with a
    /// valid capability.
    physical_action_permitted: bool = true,
};

/// Why an access was refused.
///
/// A distinct reason per cause, so a refusal can be explained rather than
/// reported as a single opaque denial. The whole point of gating access is lost
/// if the person cannot be told which gate closed.
pub const Refusal = enum {
    /// No capability was presented, or it does not cover this device class.
    not_authorized,
    /// The capability covers the class but not this access on it.
    access_not_granted,
    /// The class requires a person present and none is.
    person_required,
    /// The device is in a state that forbids physical action right now.
    physically_locked_out,

    pub fn describe(refusal: Refusal) []const u8 {
        return switch (refusal) {
            .not_authorized => "no capability authorizes this device",
            .access_not_granted => "this capability does not permit this action on the device",
            .person_required => "this device may only be used with someone present",
            .physically_locked_out => "the device is not in a state that permits physical action",
        };
    }
};

/// What a capability says about device access.
///
/// Derived from a real capability by the control plane before this policy runs;
/// carried here as the two facts the decision needs, so the policy does not
/// reach into the capability's internals.
pub const Grant = struct {
    /// The device classes this capability covers.
    classes: std.EnumSet(DeviceClass),
    /// The accesses it permits on those classes.
    accesses: std.EnumSet(Access),
};

/// The capture indicators currently lit, one per class a person can see.
pub const Indicator = struct {
    lit: std.EnumSet(DeviceClass) = .initEmpty(),

    pub fn isLit(indicator: Indicator, class: DeviceClass) bool {
        return indicator.lit.contains(class);
    }
};

/// Proof that a capture indicator is lit for a class.
///
/// It cannot be constructed by naming its fields: the witness field's type is
/// private to this module, so the only way to obtain one is through
/// `CaptureObligation.begin`, which lights the indicator first. A code path that
/// holds an `ActiveCapture` has therefore already lit the light — the state
/// "capturing but unlit" is not representable, which is what makes the indicator
/// unbypassable rather than merely advised.
pub const ActiveCapture = struct {
    class: DeviceClass,
    witness: Witness,

    const Witness = struct {};
};

/// The obligation a capture-activating allow carries: to proceed, the caller must
/// light the indicator, and doing so is the only way to get the token that lets
/// the capture start.
pub const CaptureObligation = struct {
    class: DeviceClass,

    /// Lights the indicator for the class and yields the proof of it. This is the
    /// single path from an allowed capture to actually capturing.
    pub fn begin(obligation: CaptureObligation, indicator: *Indicator) ActiveCapture {
        indicator.lit.insert(obligation.class);
        return .{ .class = obligation.class, .witness = .{} };
    }
};

/// What an allowed access lets the caller do.
pub const Allowance = union(enum) {
    /// Nothing is captured, so there is no indicator to light.
    no_capture,
    /// Sensing starts, so the indicator must be lit; the obligation is the only
    /// way to begin.
    capture: CaptureObligation,
};

/// The outcome of an access attempt.
pub const Decision = union(enum) {
    /// The access is permitted. A capture-activating access carries an obligation
    /// that can only be discharged by lighting the indicator.
    allow: Allowance,
    /// The access is refused, with the reason.
    deny: Refusal,

    pub fn isAllowed(decision: Decision) bool {
        return decision == .allow;
    }

    /// Whether this decision, if allowed, lights a capture indicator.
    pub fn lightsIndicator(decision: Decision) bool {
        return switch (decision) {
            .allow => |allowance| allowance == .capture,
            .deny => false,
        };
    }
};

/// Decides whether an access is permitted.
///
/// The checks run cheapest-and-most-fundamental first: authority before
/// presence, presence before physical state. A device that fails the authority
/// check is refused for that reason regardless of anything else, because "you
/// hold no capability for this" is a more basic answer than "and also nobody is
/// present".
pub fn decide(
    class: DeviceClass,
    access: Access,
    grant: Grant,
    situation: Situation,
) Decision {
    // Authority first: a capability that does not cover the class authorizes
    // nothing on it, whatever else is true.
    if (!grant.classes.contains(class)) return .{ .deny = .not_authorized };
    if (!grant.accesses.contains(access)) return .{ .deny = .access_not_granted };

    // Presence: the classes whose misuse a person could not otherwise notice
    // require that a person is present to have allowed it. Biometric and
    // location join the capture classes here because reading them silently is
    // exactly the harm.
    if (requiresPresence(class) and !situation.person_present) {
        return .{ .deny = .person_required };
    }

    // Physical state: an actuator obeys the device's safety state even with a
    // valid capability and a person present. A capability is permission; it is
    // not an override of a safety hold.
    if (class.isPhysicallyConsequential() and
        access == .actuate and
        !situation.physical_action_permitted)
    {
        return .{ .deny = .physically_locked_out };
    }

    if (class.showsCaptureIndicator() and access.activatesSensor()) {
        return .{ .allow = .{ .capture = .{ .class = class } } };
    }
    return .{ .allow = .no_capture };
}

/// Whether a class may only be used with a person present.
///
/// The classes whose silent use is the harm: a camera or microphone recording
/// unnoticed, a fingerprint read without consent, a location tracked in the
/// background. The passive sensor class and the display are not on this list,
/// so a step counter or a screen update does not demand a person be looking.
fn requiresPresence(class: DeviceClass) bool {
    return switch (class) {
        .camera, .microphone, .biometric, .location => true,
        .radio, .actuator, .sensor, .display => false,
    };
}

fn grantOf(
    classes: []const DeviceClass,
    accesses: []const Access,
) Grant {
    var class_set: std.EnumSet(DeviceClass) = .initEmpty();
    for (classes) |class| class_set.insert(class);
    var access_set: std.EnumSet(Access) = .initEmpty();
    for (accesses) |access| access_set.insert(access);
    return .{ .classes = class_set, .accesses = access_set };
}

const present: Situation = .{ .person_present = true, .physical_action_permitted = true };

test "a class the capability does not cover is refused as unauthorized" {
    const grant = grantOf(&.{.display}, &.{ .read, .stream, .actuate, .configure });
    const decision = decide(.camera, .read, grant, present);
    try std.testing.expectEqual(Decision{ .deny = .not_authorized }, decision);
}

test "an access the capability does not grant is refused distinctly" {
    // The capability covers the camera but only to configure it, not to stream.
    const grant = grantOf(&.{.camera}, &.{.configure});
    const decision = decide(.camera, .stream, grant, present);
    try std.testing.expectEqual(Decision{ .deny = .access_not_granted }, decision);
}

test "a capture class requires a person present" {
    const grant = grantOf(&.{.microphone}, &.{.stream});
    const absent: Situation = .{ .person_present = false };

    try std.testing.expectEqual(
        Decision{ .deny = .person_required },
        decide(.microphone, .stream, grant, absent),
    );
    try std.testing.expect(decide(.microphone, .stream, grant, present).isAllowed());
}

test "location and biometrics also require a person" {
    // Reading either silently is the harm, so both are gated the same way as
    // the capture classes.
    for ([_]DeviceClass{ .location, .biometric }) |class| {
        const grant = grantOf(&.{class}, &.{.read});
        try std.testing.expectEqual(
            Decision{ .deny = .person_required },
            decide(class, .read, grant, .{ .person_present = false }),
        );
    }
}

test "a passive sensor and the display do not require a person" {
    // A step counter or a screen update must not demand that someone be looking.
    const sensor_grant = grantOf(&.{.sensor}, &.{.read});
    try std.testing.expect(decide(.sensor, .read, sensor_grant, .{}).isAllowed());

    const display_grant = grantOf(&.{.display}, &.{.stream});
    try std.testing.expect(decide(.display, .stream, display_grant, .{}).isAllowed());
}

test "an actuator obeys a physical lockout even with a valid capability" {
    const grant = grantOf(&.{.actuator}, &.{.actuate});
    const locked: Situation = .{ .person_present = true, .physical_action_permitted = false };

    // A capability is permission, not an override of a safety hold.
    try std.testing.expectEqual(
        Decision{ .deny = .physically_locked_out },
        decide(.actuator, .actuate, grant, locked),
    );
    try std.testing.expect(decide(.actuator, .actuate, grant, present).isAllowed());
}

test "using a camera lights the capture indicator" {
    const grant = grantOf(&.{.camera}, &.{ .read, .stream, .configure });

    // Reading or streaming activates the sensor and must light the indicator.
    try std.testing.expect(decide(.camera, .stream, grant, present).lightsIndicator());
    try std.testing.expect(decide(.camera, .read, grant, present).lightsIndicator());

    // Configuring it while off does not activate the sensor, so no light.
    try std.testing.expect(!decide(.camera, .configure, grant, present).lightsIndicator());
}

test "a capture cannot begin without lighting the indicator" {
    const grant = grantOf(&.{.camera}, &.{.stream});
    const decision = decide(.camera, .stream, grant, present);

    // The only way to act on the allow is to discharge the obligation, which
    // lights the indicator and hands back the proof. There is no path that
    // starts capturing while the light is off.
    var indicator: Indicator = .{};
    try std.testing.expect(!indicator.isLit(.camera));

    const obligation = decision.allow.capture;
    const active = obligation.begin(&indicator);

    try std.testing.expect(indicator.isLit(.camera));
    try std.testing.expectEqual(DeviceClass.camera, active.class);
}

test "a non-capture device never lights the capture indicator" {
    const grant = grantOf(&.{.radio}, &.{ .read, .stream, .actuate, .configure });
    for ([_]Access{ .read, .stream, .actuate, .configure }) |access| {
        const decision = decide(.radio, access, grant, present);
        if (decision.isAllowed()) {
            try std.testing.expect(!decision.lightsIndicator());
            try std.testing.expect(decision.allow == .no_capture);
        }
    }
}

test "authority is checked before presence" {
    // A camera the capability does not cover is refused as unauthorized, not as
    // person-required, even when nobody is present. The more basic answer wins.
    const grant = grantOf(&.{.display}, &.{.read});
    try std.testing.expectEqual(
        Decision{ .deny = .not_authorized },
        decide(.camera, .read, grant, .{ .person_present = false }),
    );
}

test "every refusal explains itself" {
    for (std.enums.values(Refusal)) |refusal| {
        try std.testing.expect(refusal.describe().len > 0);
    }
}

test "no access is ambient: an empty grant authorizes nothing" {
    const nothing = grantOf(&.{}, &.{});
    // The most privileged software still presents a capability. An empty one
    // reaches no device at all.
    for (std.enums.values(DeviceClass)) |class| {
        for (std.enums.values(Access)) |access| {
            try std.testing.expect(!decide(class, access, nothing, present).isAllowed());
        }
    }
}

test "a full grant still cannot move a locked-out actuator" {
    // Even everything-permitted does not override a physical safety state.
    const everything = grantOf(
        &.{ .camera, .microphone, .location, .radio, .biometric, .actuator, .sensor, .display },
        &.{ .read, .stream, .actuate, .configure },
    );
    const locked: Situation = .{ .person_present = true, .physical_action_permitted = false };
    try std.testing.expectEqual(
        Decision{ .deny = .physically_locked_out },
        decide(.actuator, .actuate, everything, locked),
    );
}

test "the capture classes are exactly the two that light an indicator" {
    var indicator_classes: usize = 0;
    for (std.enums.values(DeviceClass)) |class| {
        if (class.showsCaptureIndicator()) indicator_classes += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), indicator_classes);
}
