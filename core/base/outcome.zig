//! The typed failure vocabulary shared by every domain module.
//!
//! Errors are actionable: each one tells the caller what to do differently.
//! Expected denial and budget exhaustion are domain outcomes rather than
//! crashes, so callers handle them on the normal control path.
//!
//! User-visible text derived from these values must not expose secrets or raw
//! internal identifiers. The `describe` function returns exactly that reduced
//! form; diagnostic context belongs in the audit ledger and structured logs.

const std = @import("std");

/// Every way a privileged operation can fail. This set is closed: a new failure
/// mode is added deliberately, with the tests and audit handling that go with
/// it, rather than by widening an existing member's meaning.
pub const DomainError = error{
    /// The principal holds no authority for this operation.
    Unauthorized,
    /// A capability existed but its validity window has passed.
    CapabilityExpired,
    /// A capability was withdrawn by its issuer or by policy.
    CapabilityRevoked,
    /// Authority exists but a declared constraint rejects this use.
    ConstraintViolation,
    /// A CPU, memory, invocation, or other budget is exhausted.
    BudgetExhausted,
    /// The work was cancelled, transitively or directly.
    Cancelled,
    /// A deadline elapsed before the work completed.
    DeadlineExceeded,
    /// A dependency is not reachable or not running.
    Unavailable,
    /// The request is malformed or fails validation.
    InvalidInput,
    /// A signature, digest, or generation check failed.
    IntegrityFailure,
    /// The operation conflicts with concurrent state.
    Conflict,
    /// The operation is well-formed but not implemented here.
    Unsupported,
    /// An invariant broke. This is a defect, not a user error.
    InternalFault,
};

/// How an attempted operation resolved. Recorded on every audit event so the
/// ledger distinguishes what was tried from what took effect.
pub const Outcome = enum {
    /// The operation completed and its effects are durable.
    succeeded,
    /// The operation was rejected before any effect occurred.
    denied,
    /// The operation began and failed; compensation may be required.
    failed,
    /// The operation stopped at a cancellation point with no partial effect.
    cancelled,
    /// The operation is held pending a human decision.
    awaiting_approval,
    /// The operation reached an external system whose result is unknown.
    ///
    /// This is deliberately distinct from `failed`. A non-idempotent action
    /// with an unknown result must never be blindly retried.
    outcome_unknown,

    /// Whether the operation is known to have produced no effect. Retry is
    /// only safe without compensation when this is true.
    pub fn hadNoEffect(outcome: Outcome) bool {
        return switch (outcome) {
            .denied, .cancelled, .awaiting_approval => true,
            .succeeded, .failed, .outcome_unknown => false,
        };
    }

    /// Whether this outcome closes the operation. `awaiting_approval` does not.
    pub fn isTerminal(outcome: Outcome) bool {
        return outcome != .awaiting_approval;
    }
};

/// Maps a failure onto the outcome the ledger records for it.
pub fn outcomeOf(domain_error: DomainError) Outcome {
    return switch (domain_error) {
        error.Unauthorized,
        error.CapabilityExpired,
        error.CapabilityRevoked,
        error.ConstraintViolation,
        error.BudgetExhausted,
        error.InvalidInput,
        error.Unsupported,
        => .denied,
        error.Cancelled => .cancelled,
        error.DeadlineExceeded,
        error.Unavailable,
        error.Conflict,
        error.IntegrityFailure,
        error.InternalFault,
        => .failed,
    };
}

/// Stable, user-safe description. Contains no identifiers, no secrets, and no
/// internal state, so it is safe to render on any surface.
pub fn describe(domain_error: DomainError) []const u8 {
    return switch (domain_error) {
        error.Unauthorized => "not authorized",
        error.CapabilityExpired => "authority expired",
        error.CapabilityRevoked => "authority revoked",
        error.ConstraintViolation => "outside the granted limits",
        error.BudgetExhausted => "budget exhausted",
        error.Cancelled => "cancelled",
        error.DeadlineExceeded => "deadline exceeded",
        error.Unavailable => "temporarily unavailable",
        error.InvalidInput => "request not valid",
        error.IntegrityFailure => "integrity check failed",
        error.Conflict => "conflicts with a concurrent change",
        error.Unsupported => "not supported",
        error.InternalFault => "internal fault",
    };
}

test "every error maps to an outcome and a description" {
    inline for (@typeInfo(DomainError).error_set.?) |member| {
        const domain_error = @field(DomainError, member.name);
        _ = outcomeOf(domain_error);
        try std.testing.expect(describe(domain_error).len > 0);
    }
}

test "denials are recorded as having produced no effect" {
    const denials = [_]DomainError{
        error.Unauthorized,
        error.CapabilityExpired,
        error.CapabilityRevoked,
        error.ConstraintViolation,
        error.BudgetExhausted,
    };
    for (denials) |domain_error| {
        const outcome = outcomeOf(domain_error);
        try std.testing.expectEqual(Outcome.denied, outcome);
        try std.testing.expect(outcome.hadNoEffect());
    }
}

test "an unknown external result is never treated as effect-free" {
    // Retrying a non-idempotent action on this outcome would duplicate it.
    try std.testing.expect(!Outcome.outcome_unknown.hadNoEffect());
    try std.testing.expect(Outcome.outcome_unknown.isTerminal());
}

test "awaiting approval is the only non-terminal outcome" {
    for (std.enums.values(Outcome)) |outcome| {
        const expected = outcome != .awaiting_approval;
        try std.testing.expectEqual(expected, outcome.isTerminal());
    }
}

test "user-visible descriptions leak no identifiers" {
    inline for (@typeInfo(DomainError).error_set.?) |member| {
        const text = describe(@field(DomainError, member.name));
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '#') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '/') == null);
        for (text) |character| try std.testing.expect(!std.ascii.isDigit(character));
    }
}
