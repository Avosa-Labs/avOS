//! What the system does the moment it detects it may be compromised.
//!
//! A security incident is not a single event; it is a lifecycle, and the order
//! of that lifecycle is what limits the damage. The instinct to investigate
//! first is the wrong one: a device that suspects it is compromised must contain
//! the threat before it studies it, because every second spent understanding an
//! attack is a second the attacker keeps working. So the sequence is fixed —
//! detect, contain, then report and recover — and containment cannot be skipped
//! or deferred, however much a responder would rather look before acting.
//!
//! This module holds the incident state machine and the containment decision:
//! given what was detected and how severe it is, what must be shut off. It
//! performs no shutdown — cutting the network or revoking a capability is the
//! control plane's job — but it decides what containment requires and enforces
//! that the phases happen in order, so no path reaches recovery on a threat it
//! never contained.

const std = @import("std");

/// What kind of thing was detected.
pub const Kind = enum {
    /// A boot or runtime integrity check failed: code is not what it should be.
    integrity_failure,
    /// A capability was used in a way its constraints forbid, suggesting the
    /// holder is compromised.
    capability_abuse,
    /// A component tried to reach outside its sandbox.
    sandbox_escape_attempt,
    /// A resource limit was breached in a pattern that looks like an attack
    /// rather than a bug.
    resource_exhaustion,
    /// An attestation from a peer did not verify: the peer may be compromised.
    peer_attestation_failure,

    /// The baseline severity this kind of detection carries. A specific incident
    /// may be escalated above it, never quietly below.
    pub fn baseSeverity(kind: Kind) Severity {
        return switch (kind) {
            // Integrity failure means the code running cannot be trusted at all.
            .integrity_failure, .sandbox_escape_attempt => .critical,
            .capability_abuse, .peer_attestation_failure => .high,
            .resource_exhaustion => .elevated,
        };
    }
};

/// How serious an incident is, which decides how much is contained.
///
/// Ordered, so containment can scale: a higher severity shuts off more.
pub const Severity = enum(u8) {
    /// Worth acting on, but the threat is bounded to one component.
    elevated = 0,
    /// The threat could spread; the affected principal is isolated.
    high = 1,
    /// The device itself may be compromised; it disconnects and locks down.
    critical = 2,

    pub fn isAtLeast(severity: Severity, floor: Severity) bool {
        return @intFromEnum(severity) >= @intFromEnum(floor);
    }
};

/// The phase an incident is in. The order is the whole point.
pub const Phase = enum(u8) {
    /// Something was detected; nothing has been contained yet.
    detected = 0,
    /// The threat has been contained: whatever it could reach is shut off.
    contained = 1,
    /// The incident is recorded and recovery may proceed, because the threat is
    /// no longer active.
    reported = 2,

    pub fn next(phase: Phase) ?Phase {
        return std.enums.fromInt(Phase, @intFromEnum(phase) + 1);
    }
};

/// What containment requires for an incident, computed from its severity.
pub const Containment = struct {
    /// Stop the offending component.
    halt_component: bool,
    /// Revoke the capabilities of the principal responsible.
    revoke_principal: bool,
    /// Cut the device's network so a compromise cannot exfiltrate or receive
    /// commands.
    disconnect_network: bool,
    /// Lock the device, requiring re-authentication.
    lock_device: bool,

    /// The containment a severity demands.
    ///
    /// It scales: every incident halts the component; a spreading threat also
    /// revokes the principal; a device-level compromise also disconnects and
    /// locks. More severe never contains less.
    pub fn forSeverity(severity: Severity) Containment {
        return .{
            .halt_component = true,
            .revoke_principal = severity.isAtLeast(.high),
            .disconnect_network = severity.isAtLeast(.critical),
            .lock_device = severity.isAtLeast(.critical),
        };
    }

    /// Whether this containment is at least as strict as another. Used to check
    /// the scaling property holds.
    pub fn isAtLeastAsStrictAs(a: Containment, b: Containment) bool {
        return (a.halt_component or !b.halt_component) and
            (a.revoke_principal or !b.revoke_principal) and
            (a.disconnect_network or !b.disconnect_network) and
            (a.lock_device or !b.lock_device);
    }
};

pub const Error = error{
    /// An operation was attempted out of phase order: recovery before
    /// containment, most importantly.
    OutOfOrder,
    /// Containment was skipped. The one transition that must never be allowed.
    ContainmentSkipped,
};

/// An incident as it moves through its lifecycle.
pub const Incident = struct {
    kind: Kind,
    severity: Severity,
    phase: Phase = .detected,

    /// Opens an incident, taking the greater of the kind's baseline severity and
    /// any escalation the detector supplied. It never starts below the baseline.
    pub fn detect(kind: Kind, escalated_to: ?Severity) Incident {
        const base = kind.baseSeverity();
        const severity = if (escalated_to) |escalation|
            (if (escalation.isAtLeast(base)) escalation else base)
        else
            base;
        return .{ .kind = kind, .severity = severity };
    }

    /// The containment this incident requires.
    pub fn containment(incident: Incident) Containment {
        return Containment.forSeverity(incident.severity);
    }

    /// Advances to contained. May only run from detected.
    pub fn markContained(incident: *Incident) Error!void {
        if (incident.phase != .detected) return error.OutOfOrder;
        incident.phase = .contained;
    }

    /// Advances to reported. May only run once contained: the threat must be
    /// shut off before it is written up, or the write-up races the attack.
    pub fn markReported(incident: *Incident) Error!void {
        if (incident.phase == .detected) return error.ContainmentSkipped;
        if (incident.phase != .contained) return error.OutOfOrder;
        incident.phase = .reported;
    }

    /// Whether recovery may begin: only after the incident is reported, which is
    /// only after it is contained.
    pub fn mayRecover(incident: Incident) bool {
        return incident.phase == .reported;
    }
};

test "each detection kind carries a baseline severity" {
    try std.testing.expectEqual(Severity.critical, Kind.integrity_failure.baseSeverity());
    try std.testing.expectEqual(Severity.critical, Kind.sandbox_escape_attempt.baseSeverity());
    try std.testing.expectEqual(Severity.high, Kind.capability_abuse.baseSeverity());
    try std.testing.expectEqual(Severity.elevated, Kind.resource_exhaustion.baseSeverity());
}

test "an incident never starts below its baseline severity" {
    // A detector that tried to open an integrity failure as merely elevated is
    // overruled: it starts critical.
    const incident = Incident.detect(.integrity_failure, .elevated);
    try std.testing.expectEqual(Severity.critical, incident.severity);
}

test "a detector may escalate above the baseline" {
    const incident = Incident.detect(.resource_exhaustion, .critical);
    try std.testing.expectEqual(Severity.critical, incident.severity);
}

test "containment scales with severity and never shrinks" {
    const elevated = Containment.forSeverity(.elevated);
    const high = Containment.forSeverity(.high);
    const critical = Containment.forSeverity(.critical);

    // Every level halts the component; higher levels add more.
    try std.testing.expect(elevated.halt_component);
    try std.testing.expect(!elevated.revoke_principal);
    try std.testing.expect(high.revoke_principal);
    try std.testing.expect(!high.disconnect_network);
    try std.testing.expect(critical.disconnect_network and critical.lock_device);

    // More severe is at least as strict as less severe.
    try std.testing.expect(high.isAtLeastAsStrictAs(elevated));
    try std.testing.expect(critical.isAtLeastAsStrictAs(high));
}

test "the lifecycle runs detect, contain, report in order" {
    var incident = Incident.detect(.capability_abuse, null);
    try std.testing.expectEqual(Phase.detected, incident.phase);
    try incident.markContained();
    try std.testing.expectEqual(Phase.contained, incident.phase);
    try incident.markReported();
    try std.testing.expectEqual(Phase.reported, incident.phase);
}

test "reporting before containing is refused as skipping containment" {
    var incident = Incident.detect(.integrity_failure, null);
    // The one transition that must never be allowed: recovery-relevant reporting
    // on a threat that was never shut off.
    try std.testing.expectError(error.ContainmentSkipped, incident.markReported());
}

test "recovery may not begin until the incident is reported" {
    var incident = Incident.detect(.sandbox_escape_attempt, null);
    try std.testing.expect(!incident.mayRecover());
    try incident.markContained();
    // Contained but not yet reported: still not clear to recover.
    try std.testing.expect(!incident.mayRecover());
    try incident.markReported();
    try std.testing.expect(incident.mayRecover());
}

test "containment cannot be repeated" {
    var incident = Incident.detect(.capability_abuse, null);
    try incident.markContained();
    // Marking contained again is out of order; the phase only moves forward.
    try std.testing.expectError(error.OutOfOrder, incident.markContained());
}

test "a critical incident contains the whole device" {
    const incident = Incident.detect(.integrity_failure, null);
    const containment = incident.containment();
    try std.testing.expect(containment.halt_component);
    try std.testing.expect(containment.revoke_principal);
    try std.testing.expect(containment.disconnect_network);
    try std.testing.expect(containment.lock_device);
}

test "no incident reaches recovery without passing through containment" {
    // Swept across every kind: the only route to mayRecover goes through
    // markContained then markReported, and skipping the first is refused.
    for (std.enums.values(Kind)) |kind| {
        var incident = Incident.detect(kind, null);
        try std.testing.expect(!incident.mayRecover());
        // Skipping containment is impossible.
        try std.testing.expectError(error.ContainmentSkipped, incident.markReported());
        // The correct order works.
        try incident.markContained();
        try incident.markReported();
        try std.testing.expect(incident.mayRecover());
    }
}

test "the severity order runs elevated, high, critical" {
    try std.testing.expect(Severity.critical.isAtLeast(.high));
    try std.testing.expect(Severity.high.isAtLeast(.elevated));
    try std.testing.expect(!Severity.elevated.isAtLeast(.high));
}
