//! Deciding whether a submitted app passes review, so nothing reaches the catalogue that
//! violates policy, hides undeclared capability use, or ships known-malicious code.
//!
//! Review is the gate between a developer's submission and a person's device, and it exists
//! because a store's whole promise is that installing from it is safe. Three checks decide the
//! verdict, and any one failing rejects. The app must comply with content and conduct policy,
//! because a store that lists what it forbids has forbidden nothing. Its declared capabilities
//! must match what it actually uses — an app that requests the microphone must use it for a
//! stated purpose, and one found using a capability it did not declare is hiding something,
//! which is disqualifying whatever the capability. And it must be clear of known malware
//! signatures, because shipping code already known to be malicious is the one failure a store
//! can never explain away. An app that passes all three is approved; one that fails any is
//! rejected with the reason, so the developer knows what to fix and the person is protected.
//!
//! This module reviews no code. It decides the review verdict from the policy, capability, and
//! malware checks, as a pure function.

const std = @import("std");

/// The outcome of the automated and human review checks on a submission.
pub const Checks = struct {
    /// Whether the app complies with content and conduct policy.
    policy_compliant: bool,
    /// Whether every capability the app uses was declared, with no undeclared use found.
    capabilities_declared: bool,
    /// Whether the app is clear of known malware signatures.
    malware_clear: bool,
};

/// Why an app was rejected.
pub const Rejection = enum {
    /// The app violates content or conduct policy.
    policy_violation,
    /// The app uses a capability it did not declare.
    undeclared_capability,
    /// The app matches a known malware signature.
    malware_detected,
};

/// The review verdict.
pub const Verdict = union(enum) {
    approve,
    reject: Rejection,

    pub fn approved(verdict: Verdict) bool {
        return verdict == .approve;
    }
};

/// Decides the review verdict.
///
/// Malware is checked first, because known-malicious code is the most serious finding and no
/// other merit outweighs it. Then undeclared capability use, because an app hiding what it does
/// cannot be trusted whatever else it passes. Then policy compliance. Every check is a hard
/// gate; an app is approved only when all three pass.
pub fn review(checks: Checks) Verdict {
    if (!checks.malware_clear) return .{ .reject = .malware_detected };
    if (!checks.capabilities_declared) return .{ .reject = .undeclared_capability };
    if (!checks.policy_compliant) return .{ .reject = .policy_violation };
    return .approve;
}

fn makeChecks(policy: bool, capabilities: bool, malware_clear: bool) Checks {
    return .{ .policy_compliant = policy, .capabilities_declared = capabilities, .malware_clear = malware_clear };
}

test "an app passing every check is approved" {
    try std.testing.expect(review(makeChecks(true, true, true)).approved());
}

test "malware is rejected first" {
    try std.testing.expectEqual(Verdict{ .reject = .malware_detected }, review(makeChecks(false, false, false)));
}

test "undeclared capability use is rejected" {
    try std.testing.expectEqual(Verdict{ .reject = .undeclared_capability }, review(makeChecks(true, false, true)));
}

test "a policy violation is rejected" {
    try std.testing.expectEqual(Verdict{ .reject = .policy_violation }, review(makeChecks(false, true, true)));
}

test "any single failed check rejects the app, swept" {
    // The all-gates property: approval requires policy AND capabilities AND malware-clear.
    try std.testing.expect(review(makeChecks(true, true, true)).approved());
    try std.testing.expect(!review(makeChecks(false, true, true)).approved());
    try std.testing.expect(!review(makeChecks(true, false, true)).approved());
    try std.testing.expect(!review(makeChecks(true, true, false)).approved());
}
