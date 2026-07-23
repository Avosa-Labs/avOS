//! Deciding whether deferrable work may run now, given what the device can
//! afford.
//!
//! Background work — indexing, backups, prefetching, an agent's speculative
//! preparation — is work nobody is waiting on, which is exactly why it must
//! yield to everything a person is waiting on and to the device's own health. A
//! backup that runs while the battery is critical, or a prefetch that fires on a
//! metered link, or an index rebuild during an active phone call, is background
//! work that stopped being in the background. So it does not simply run when
//! queued; it is admitted only when the device can afford it, and the same job
//! waits, unchanged, until it can.
//!
//! This is the admission decision, composed from the state other modules already
//! decide: the power state the battery policy reports, the network the
//! reachability policy chose, and the scheduling class the kernel policy defines.
//! It runs no job and holds no queue; it answers whether a job of a given class,
//! with given needs, may start right now, so the same rule governs every kind of
//! background work rather than each subsystem inventing its own.

const std = @import("std");

/// The scheduling classes background work can belong to, mirroring the kernel
/// policy's lower tiers. Duplicated as a small local enum rather than imported,
/// because a service must not depend on the kernel module directly; the control
/// plane maps between them.
pub const SchedulerClass = enum {
    /// Work explicitly requested and still useful, run in the background.
    committed,
    /// Indexing, cleanup, updates, backups.
    maintenance,
    /// Prediction and proactive preparation with no committed output.
    speculative,
};

/// The device conditions an admission decision reads.
pub const Conditions = struct {
    /// Whether the battery permits background work at all. The battery policy
    /// reports this; below `low` it is false.
    power_permits_background: bool,
    /// Whether an unmetered network is available, for work that needs the
    /// network.
    unmetered_network: bool,
    /// Whether a person is actively interacting, in which case only committed
    /// work runs so the device stays responsive.
    person_active: bool,
    /// Whether the device is thermally throttled, in which case only committed
    /// work runs so heat is not added to a hot device.
    thermally_throttled: bool,
};

/// What a background job needs to run.
pub const Needs = struct {
    class: SchedulerClass,
    /// Whether the job moves data over the network.
    network: bool = false,
};

/// Why a job was not admitted.
pub const Refusal = enum {
    /// The battery is too low for background work.
    power_too_low,
    /// The job needs the network but only a metered one is available.
    would_be_metered,
    /// A person is interacting; non-committed work waits so the device stays
    /// responsive.
    person_active,
    /// The device is hot; non-committed work waits so no heat is added.
    thermally_throttled,
};

/// The admission outcome.
pub const Decision = union(enum) {
    admit,
    /// Hold the job, unchanged, until conditions allow. The same job is retried
    /// later, not dropped.
    hold: Refusal,

    pub fn isAdmitted(decision: Decision) bool {
        return decision == .admit;
    }
};

/// Decides whether a job may run now.
///
/// Committed work — still useful, explicitly requested — is the most privileged
/// background class and runs whenever the battery permits and its network is
/// available, even during interaction or throttling, because it is work the
/// person asked for. The lower classes additionally yield to an active person
/// and to thermal throttling, because their whole nature is to be deferrable.
/// Every class yields to a battery too low to spend, and any network job yields
/// to a metered-only link so the person is never charged for background traffic.
pub fn decide(needs: Needs, conditions: Conditions) Decision {
    // Power is the floor for everything: no background class runs on a battery
    // too low to spend on it.
    if (!conditions.power_permits_background) return .{ .hold = .power_too_low };

    // Network jobs never run on a metered link: the person did not agree to pay
    // for background traffic.
    if (needs.network and !conditions.unmetered_network) return .{ .hold = .would_be_metered };

    // The deferrable classes yield to an active person and to a hot device.
    // Committed work does not, because the person asked for it.
    if (needs.class != .committed) {
        if (conditions.person_active) return .{ .hold = .person_active };
        if (conditions.thermally_throttled) return .{ .hold = .thermally_throttled };
    }

    return .admit;
}

const good_conditions: Conditions = .{
    .power_permits_background = true,
    .unmetered_network = true,
    .person_active = false,
    .thermally_throttled = false,
};

test "committed work runs whenever power and network allow" {
    // Even during interaction and throttling, because the person asked for it.
    var conditions = good_conditions;
    conditions.person_active = true;
    conditions.thermally_throttled = true;
    try std.testing.expect(decide(.{ .class = .committed }, conditions).isAdmitted());
}

test "maintenance yields to an active person" {
    var conditions = good_conditions;
    conditions.person_active = true;
    try std.testing.expectEqual(
        Decision{ .hold = .person_active },
        decide(.{ .class = .maintenance }, conditions),
    );
    // With the person idle, it runs.
    try std.testing.expect(decide(.{ .class = .maintenance }, good_conditions).isAdmitted());
}

test "speculative work yields to thermal throttling" {
    var conditions = good_conditions;
    conditions.thermally_throttled = true;
    try std.testing.expectEqual(
        Decision{ .hold = .thermally_throttled },
        decide(.{ .class = .speculative }, conditions),
    );
}

test "no class runs on a battery too low" {
    var conditions = good_conditions;
    conditions.power_permits_background = false;
    // The floor applies to committed work too: even asked-for background work
    // yields when the battery cannot spend.
    for (std.enums.values(SchedulerClass)) |class| {
        try std.testing.expectEqual(
            Decision{ .hold = .power_too_low },
            decide(.{ .class = class }, conditions),
        );
    }
}

test "a network job yields to a metered-only link" {
    var conditions = good_conditions;
    conditions.unmetered_network = false;
    try std.testing.expectEqual(
        Decision{ .hold = .would_be_metered },
        decide(.{ .class = .maintenance, .network = true }, conditions),
    );
    // A job that needs no network is unaffected.
    try std.testing.expect(decide(.{ .class = .maintenance, .network = false }, conditions).isAdmitted());
}

test "power is checked before the network" {
    // A low battery holds for power, not for the metered link, so the person is
    // told the more fundamental reason.
    var conditions = good_conditions;
    conditions.power_permits_background = false;
    conditions.unmetered_network = false;
    try std.testing.expectEqual(
        Decision{ .hold = .power_too_low },
        decide(.{ .class = .maintenance, .network = true }, conditions),
    );
}

test "committed network work still yields to a metered link" {
    // Committed work is privileged against interaction and heat, but not against
    // spending the person's money on background traffic.
    var conditions = good_conditions;
    conditions.unmetered_network = false;
    try std.testing.expectEqual(
        Decision{ .hold = .would_be_metered },
        decide(.{ .class = .committed, .network = true }, conditions),
    );
}

test "a held job is the same job retried, not dropped" {
    // The decision holds rather than failing, so a caller retries the identical
    // job when conditions change. This is a property of the return type: hold
    // carries a reason, never a mutation of the job.
    var conditions = good_conditions;
    conditions.person_active = true;
    const first = decide(.{ .class = .maintenance }, conditions);
    conditions.person_active = false;
    const second = decide(.{ .class = .maintenance }, conditions);
    try std.testing.expect(!first.isAdmitted());
    try std.testing.expect(second.isAdmitted());
}

test "under ideal conditions every class is admitted" {
    for (std.enums.values(SchedulerClass)) |class| {
        try std.testing.expect(decide(.{ .class = class }, good_conditions).isAdmitted());
    }
}
