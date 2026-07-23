//! Where a piece of data came from, and what it is therefore allowed to become.
//!
//! The platform's central safety claim is that model output is untrusted
//! computation, and untrusted data must not become a task, a capability request,
//! an external action, or a durable fact without first being validated. Holding
//! that claim requires knowing, for any value in hand, where it came from — and
//! that origin must travel with the value, because the danger is precisely that
//! untrusted input launders itself into a trusted decision by passing through
//! enough hands that nobody remembers its source.
//!
//! This module is the label and its algebra. A value carries an origin; when two
//! values are combined the result carries the more suspect of the two, because a
//! trusted fact mixed with an untrusted one is no longer trustworthy; and an
//! origin only ever becomes more trusted by passing an explicit validation that
//! is itself recorded, never by being copied or by being combined with something
//! cleaner. A value cannot be trusted into existence.

const std = @import("std");

/// Where a value originated, ordered from most to least trustworthy.
///
/// The order is the point: a comparison decides which of two origins is more
/// suspect, and combining always keeps the worse one. The numeric values encode
/// the order, so lower is more trusted.
pub const Origin = enum(u8) {
    /// Produced by the trusted control plane itself. The root of trust for data.
    control_plane = 0,
    /// Entered by an authenticated human through a trusted surface. A person's
    /// deliberate input.
    human_input = 1,
    /// Read from durable state the system wrote and verified. Trusted because it
    /// was validated before it was stored.
    verified_storage = 2,
    /// Received from another endpoint over an authenticated session. Trusted to
    /// the extent that endpoint is.
    authenticated_peer = 3,
    /// Produced by a language model. Untrusted computation: plausible, useful,
    /// and not to be believed without validation.
    model_output = 4,
    /// Received from outside the device: a network response, a scanned tag, a
    /// file from elsewhere. The least trusted, because anyone could have authored
    /// it.
    external_input = 5,

    /// Whether this origin may be acted on without an intervening validation.
    ///
    /// The two untrusted origins may not. A value from either becomes actionable
    /// only by passing a validation that upgrades its origin and is recorded.
    pub fn isTrusted(origin: Origin) bool {
        return @intFromEnum(origin) < @intFromEnum(Origin.model_output);
    }

    /// The more suspect of two origins.
    ///
    /// The heart of the algebra: combining values keeps the worse origin, so
    /// trusted data mixed with untrusted data is untrusted, never the reverse.
    pub fn moreSuspect(a: Origin, b: Origin) Origin {
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }
};

/// What a validated value is now permitted to become.
///
/// A validation upgrades an untrusted origin to one of these, and only to the
/// one the validation actually checked for. A value validated as safe to display
/// has not thereby been validated as safe to execute.
pub const Clearance = enum {
    /// May be shown to a person. Checked for nothing but rendering safety.
    display,
    /// May become a durable fact the system stores and later trusts.
    durable_fact,
    /// May become a task the system executes.
    task,
    /// May become a capability request.
    capability_request,
    /// May drive an external action that leaves the device.
    external_action,
};

/// A value's provenance: where it came from and what validations it has passed.
///
/// Carried alongside the value it describes. The set of clearances starts empty
/// and only grows by explicit validation; nothing here mutates an origin toward
/// trust on its own.
pub const Provenance = struct {
    origin: Origin,
    /// Which clearances have been granted by validation. An untrusted origin
    /// with an empty set may be acted on for nothing.
    clearances: std.EnumSet(Clearance) = .initEmpty(),

    /// A value straight from an origin, cleared for nothing.
    pub fn from(origin: Origin) Provenance {
        return .{ .origin = origin };
    }

    /// Whether this value may be used for a purpose.
    ///
    /// A trusted origin may be used for a purpose without an explicit clearance,
    /// because it was trusted at its source. An untrusted origin may be used
    /// only for a purpose it has been explicitly validated for.
    pub fn permits(provenance: Provenance, clearance: Clearance) bool {
        if (provenance.origin.isTrusted()) return true;
        return provenance.clearances.contains(clearance);
    }

    /// Combines two provenances, as when two values are merged into one.
    ///
    /// The result carries the more suspect origin and only the clearances both
    /// inputs share, because a clearance one value earned does not vouch for the
    /// other it is now mixed with.
    pub fn combine(a: Provenance, b: Provenance) Provenance {
        return .{
            .origin = a.origin.moreSuspect(b.origin),
            .clearances = a.clearances.intersectWith(b.clearances),
        };
    }
};

/// A recorded validation: the act that grants a clearance.
///
/// Returning this rather than mutating in place makes the upgrade a visible
/// event a caller must handle, and gives the audit ledger something to record.
/// An untrusted value becoming actionable is exactly the moment worth logging.
pub const Validation = struct {
    /// The clearance granted.
    clearance: Clearance,
    /// The provenance after validation.
    result: Provenance,
};

/// Validates a value for a purpose, upgrading its provenance.
///
/// This is the only way an untrusted value becomes actionable, and the caller
/// supplies the verdict — the actual checking (a parser that confirms structure,
/// a policy that confirms safety) lives with whoever knows the purpose. What
/// this guarantees is the bookkeeping: a granted clearance is added, an origin
/// that was untrusted is marked validated for exactly that purpose and no other,
/// and the event is a value a caller cannot ignore.
pub fn validate(
    provenance: Provenance,
    clearance: Clearance,
    passed: bool,
) ?Validation {
    if (!passed) return null;
    var upgraded = provenance;
    upgraded.clearances.insert(clearance);
    return .{ .clearance = clearance, .result = upgraded };
}

test "the trusted origins are exactly those above the model" {
    try std.testing.expect(Origin.control_plane.isTrusted());
    try std.testing.expect(Origin.human_input.isTrusted());
    try std.testing.expect(Origin.verified_storage.isTrusted());
    try std.testing.expect(Origin.authenticated_peer.isTrusted());
    try std.testing.expect(!Origin.model_output.isTrusted());
    try std.testing.expect(!Origin.external_input.isTrusted());
}

test "combining keeps the more suspect origin" {
    // A trusted fact mixed with model output is no longer trustworthy.
    const trusted: Provenance = .from(.human_input);
    const untrusted: Provenance = .from(.model_output);
    try std.testing.expectEqual(Origin.model_output, trusted.combine(untrusted).origin);
    try std.testing.expectEqual(Origin.model_output, untrusted.combine(trusted).origin);
}

test "an untrusted value permits nothing until validated" {
    const value: Provenance = .from(.model_output);
    for (std.enums.values(Clearance)) |clearance| {
        try std.testing.expect(!value.permits(clearance));
    }
}

test "a trusted value permits any purpose without explicit clearance" {
    const value: Provenance = .from(.human_input);
    for (std.enums.values(Clearance)) |clearance| {
        try std.testing.expect(value.permits(clearance));
    }
}

test "validation upgrades exactly the purpose checked and no other" {
    const value: Provenance = .from(.model_output);
    const validation = validate(value, .display, true).?;

    // Cleared to display, and only to display: validating for one purpose is not
    // validating for another.
    try std.testing.expect(validation.result.permits(.display));
    try std.testing.expect(!validation.result.permits(.task));
    try std.testing.expect(!validation.result.permits(.external_action));
}

test "a failed validation grants nothing" {
    const value: Provenance = .from(.external_input);
    // The checker said no. Nothing is upgraded; there is no validation to hand
    // back.
    try std.testing.expectEqual(@as(?Validation, null), validate(value, .task, false));
}

test "combining keeps only the clearances both values share" {
    // One value validated for display, another for task; combined, it is
    // validated for neither, because each clearance vouches only for the value
    // that earned it.
    const displayable = validate(Provenance.from(.model_output), .display, true).?.result;
    const runnable = validate(Provenance.from(.model_output), .task, true).?.result;

    const combined = displayable.combine(runnable);
    try std.testing.expect(!combined.permits(.display));
    try std.testing.expect(!combined.permits(.task));
}

test "untrusted data cannot launder itself trusted by combining" {
    // The attack the module exists to stop: mixing untrusted input with a clean
    // value must never yield a clean result.
    const clean: Provenance = .from(.control_plane);
    const dirty: Provenance = .from(.external_input);
    const mixed = clean.combine(dirty);
    try std.testing.expect(!mixed.origin.isTrusted());
    // And it carries none of the trusted value's implicit permission.
    try std.testing.expect(!mixed.permits(.external_action));
}

test "a validated value that is then combined with untrusted data loses its clearance" {
    // Validated model output cleared for display, then mixed with fresh external
    // input: the clearance does not carry to the mixture.
    const displayable = validate(Provenance.from(.model_output), .display, true).?.result;
    const fresh: Provenance = .from(.external_input);
    const combined = displayable.combine(fresh);
    try std.testing.expect(!combined.permits(.display));
}

test "the suspicion order is total" {
    // Every pair of origins is comparable, so combining always has a defined
    // result.
    const origins = std.enums.values(Origin);
    for (origins) |a| {
        for (origins) |b| {
            const worse = a.moreSuspect(b);
            try std.testing.expect(worse == a or worse == b);
            try std.testing.expect(
                @intFromEnum(worse) >= @intFromEnum(a) and @intFromEnum(worse) >= @intFromEnum(b),
            );
        }
    }
}

test "combining is commutative in origin" {
    const origins = std.enums.values(Origin);
    for (origins) |a| {
        for (origins) |b| {
            try std.testing.expectEqual(a.moreSuspect(b), b.moreSuspect(a));
        }
    }
}

test "validation records an event a caller cannot ignore" {
    // The return is optional, so a caller must handle the grant-or-not rather
    // than a mutation happening silently.
    const value: Provenance = .from(.model_output);
    const validation = validate(value, .capability_request, true);
    try std.testing.expect(validation != null);
    try std.testing.expectEqual(Clearance.capability_request, validation.?.clearance);
}
