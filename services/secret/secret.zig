//! Deciding whether a caller may retrieve a secret, resisting brute-force guessing
//! and auditing every attempt, so secret material only ever reaches a principal
//! that was explicitly granted it.
//!
//! A secret service holds the things whose whole value is that they stay hidden:
//! signing keys, tokens, credentials. Two failures ruin such a service quietly.
//! The first is an implicit grant — returning material because the caller seemed
//! plausible rather than because a rule named them — so access is a closed
//! allow-list and a principal with no rule for a secret gets nothing, never a
//! best-effort guess. The second is unmetered guessing: a caller that can ask for
//! secret after secret, or retry a denied one endlessly, turns the service into an
//! oracle, so repeated failures from a principal lock it out. And because a secret
//! access is exactly the event an investigation needs, every decision — granted or
//! refused — is auditable, never silent.
//!
//! This module returns no secret material. It decides whether an access may
//! proceed given the grants, the principal's recent failures, and the request,
//! and reports that the decision must be recorded, as a pure function the service
//! calls before it ever touches the stored bytes.

const std = @import("std");

/// What a caller wants to do with a secret.
pub const Operation = enum {
    /// Retrieve the secret material.
    read,
    /// Replace it with a new value.
    rotate,
    /// Remove it.
    destroy,
};

/// An access grant: a principal may perform an operation on a secret. The
/// allow-list is closed — only listed (principal, secret, operation) triples are
/// permitted.
pub const Grant = struct {
    principal: u128,
    secret_id: u64,
    operation: Operation,
};

/// A principal's recent failure record, used to lock out a guesser.
pub const FailureRecord = struct {
    principal: u128,
    /// Consecutive denied attempts since the last grant.
    failures: u32 = 0,

    /// How many consecutive failures lock a principal out. Small, because a
    /// legitimate caller does not miss repeatedly, and a guesser must not get many
    /// tries.
    pub const lockout_threshold: u32 = 5;

    fn lockedOut(record: FailureRecord) bool {
        return record.failures >= lockout_threshold;
    }
};

/// A request to access a secret.
pub const Request = struct {
    principal: u128,
    secret_id: u64,
    operation: Operation,
};

/// Why an access was refused.
pub const Refusal = enum {
    /// The principal has failed too many times and is locked out; even a valid
    /// request is refused until the lockout is cleared.
    locked_out,
    /// No grant names this principal for this secret and operation. The closed
    /// allow-list refuses anything it does not explicitly permit.
    not_granted,
};

/// The outcome of an access decision.
pub const Decision = struct {
    outcome: Outcome,
    /// Every secret access decision is recorded — a grant because it is a use of a
    /// secret, a refusal because it may be an attack. Never silent.
    must_audit: bool = true,

    pub const Outcome = union(enum) {
        /// The access may proceed; the service may now touch the material.
        grant,
        /// The access is refused.
        refuse: Refusal,
    };

    pub fn granted(decision: Decision) bool {
        return decision.outcome == .grant;
    }
};

/// The secret service's access state: the grants it honours and the per-principal
/// failure records.
pub const Service = struct {
    grants: []const Grant,
    failures: []FailureRecord,

    fn hasGrant(service: Service, request: Request) bool {
        for (service.grants) |grant| {
            if (grant.principal == request.principal and
                grant.secret_id == request.secret_id and
                grant.operation == request.operation)
            {
                return true;
            }
        }
        return false;
    }

    fn recordFor(service: Service, principal: u128) ?*FailureRecord {
        for (service.failures) |*record| {
            if (record.principal == principal) return record;
        }
        return null;
    }

    /// Decides whether an access may proceed, and updates the failure record.
    ///
    /// A locked-out principal is refused before the grants are even consulted, so a
    /// guesser gets no signal about whether a secret exists. Otherwise the closed
    /// allow-list decides: a matching grant permits the access and clears the
    /// principal's failure count, because a legitimate success is evidence the
    /// principal is not an attacker; anything else is refused and counts as a
    /// failure toward the lockout. Every path is marked for audit.
    pub fn access(service: Service, request: Request) Decision {
        if (service.recordFor(request.principal)) |record| {
            if (record.lockedOut()) return .{ .outcome = .{ .refuse = .locked_out } };
        }

        if (service.hasGrant(request)) {
            if (service.recordFor(request.principal)) |record| record.failures = 0;
            return .{ .outcome = .grant };
        }

        if (service.recordFor(request.principal)) |record| record.failures +|= 1;
        return .{ .outcome = .{ .refuse = .not_granted } };
    }
};

const alice: u128 = 0xA11CE;
const mallory: u128 = 0x1337;

fn makeRequest(principal: u128, secret_id: u64, operation: Operation) Request {
    return .{ .principal = principal, .secret_id = secret_id, .operation = operation };
}

test "a granted access is permitted and audited" {
    const grants = [_]Grant{.{ .principal = alice, .secret_id = 1, .operation = .read }};
    var failures = [_]FailureRecord{.{ .principal = alice }};
    const service: Service = .{ .grants = &grants, .failures = &failures };

    const decision = service.access(makeRequest(alice, 1, .read));
    try std.testing.expect(decision.granted());
    try std.testing.expect(decision.must_audit);
}

test "an access with no grant is refused and audited" {
    const grants = [_]Grant{.{ .principal = alice, .secret_id = 1, .operation = .read }};
    var failures = [_]FailureRecord{.{ .principal = mallory }};
    const service: Service = .{ .grants = &grants, .failures = &failures };

    const decision = service.access(makeRequest(mallory, 1, .read));
    try std.testing.expectEqual(Decision.Outcome{ .refuse = .not_granted }, decision.outcome);
    try std.testing.expect(decision.must_audit);
}

test "the allow-list is closed by operation and by secret" {
    // A grant to read secret 1 does not permit rotating it or reading secret 2.
    const grants = [_]Grant{.{ .principal = alice, .secret_id = 1, .operation = .read }};
    var failures = [_]FailureRecord{.{ .principal = alice }};
    const service: Service = .{ .grants = &grants, .failures = &failures };

    try std.testing.expect(!service.access(makeRequest(alice, 1, .rotate)).granted());
    try std.testing.expect(!service.access(makeRequest(alice, 2, .read)).granted());
    try std.testing.expect(service.access(makeRequest(alice, 1, .read)).granted());
}

test "repeated failures lock a principal out" {
    const grants = [_]Grant{.{ .principal = alice, .secret_id = 1, .operation = .read }};
    var failures = [_]FailureRecord{.{ .principal = mallory }};
    const service: Service = .{ .grants = &grants, .failures = &failures };

    // Guess and fail up to the threshold.
    for (0..FailureRecord.lockout_threshold) |_| {
        try std.testing.expectEqual(
            Decision.Outcome{ .refuse = .not_granted },
            service.access(makeRequest(mallory, 1, .read)).outcome,
        );
    }
    // Now locked out: even a request that names a real secret is refused for the
    // lockout reason, giving the guesser no oracle.
    try std.testing.expectEqual(
        Decision.Outcome{ .refuse = .locked_out },
        service.access(makeRequest(mallory, 1, .read)).outcome,
    );
}

test "a success clears the failure count" {
    const grants = [_]Grant{.{ .principal = alice, .secret_id = 1, .operation = .read }};
    var failures = [_]FailureRecord{.{ .principal = alice, .failures = FailureRecord.lockout_threshold - 1 }};
    const service: Service = .{ .grants = &grants, .failures = &failures };

    // One below the threshold; a legitimate success resets the counter.
    try std.testing.expect(service.access(makeRequest(alice, 1, .read)).granted());
    try std.testing.expectEqual(@as(u32, 0), failures[0].failures);
}

test "a locked-out principal is refused before the grants are consulted" {
    // Even with a valid grant, a principal already at the lockout threshold is
    // refused for lockout, not granted.
    const grants = [_]Grant{.{ .principal = alice, .secret_id = 1, .operation = .read }};
    var failures = [_]FailureRecord{.{ .principal = alice, .failures = FailureRecord.lockout_threshold }};
    const service: Service = .{ .grants = &grants, .failures = &failures };

    try std.testing.expectEqual(
        Decision.Outcome{ .refuse = .locked_out },
        service.access(makeRequest(alice, 1, .read)).outcome,
    );
}

test "every decision is marked for audit, swept" {
    // The property an investigation depends on: no secret access decision is
    // silent, whatever its outcome.
    const grants = [_]Grant{.{ .principal = alice, .secret_id = 1, .operation = .read }};
    var failures = [_]FailureRecord{ .{ .principal = alice }, .{ .principal = mallory, .failures = FailureRecord.lockout_threshold } };
    const service: Service = .{ .grants = &grants, .failures = &failures };

    const decisions = [_]Decision{
        service.access(makeRequest(alice, 1, .read)), // grant
        service.access(makeRequest(alice, 2, .read)), // not granted
        service.access(makeRequest(mallory, 1, .read)), // locked out
    };
    for (decisions) |decision| try std.testing.expect(decision.must_audit);
}

test "an empty allow-list grants nothing" {
    var failures = [_]FailureRecord{.{ .principal = alice }};
    const service: Service = .{ .grants = &.{}, .failures = &failures };
    try std.testing.expect(!service.access(makeRequest(alice, 1, .read)).granted());
}
