//! Deciding whether an available system update is presented, deferred, or installed now, so
//! security fixes land promptly while routine updates never surprise the person or their bill.
//!
//! An update surface has to balance two pressures that pull apart. Security matters: a critical
//! fix closes a hole someone may already be exploiting, so it cannot be put off forever — past a
//! bound of deferrals it must install, or the deferral becomes a way to stay vulnerable
//! indefinitely. Trust matters too: an update that installs itself over a metered connection can
//! cost the person real money, and one that installs off power can strand a device mid-write, so
//! a routine update waits politely and installs only on the person's terms. The decision reads
//! severity, power, network, and how many times the person has already deferred, and returns
//! exactly one verdict. So urgency and courtesy are reconciled per update rather than by a
//! blanket policy.
//!
//! This module installs nothing. It decides how an update is offered, as a pure function over
//! severity, power, network, and prior deferrals.

const std = @import("std");

/// How urgent an update is, which decides how much deferral it tolerates.
pub const Severity = enum {
    /// A feature or maintenance update; fully deferrable, installs only on the person's terms.
    routine,
    /// A security fix; deferrable but pressed sooner.
    security,
    /// A security fix for an actively dangerous hole; deferrable only up to a hard bound.
    critical,
};

/// How many times a critical update may be deferred before it must install.
///
/// A critical fix stays deferrable so it never interrupts something urgent, but only up to this
/// bound — beyond it the risk of staying unpatched outweighs the interruption, and the update
/// installs regardless.
pub const critical_defer_limit: u8 = 3;

/// The verdict for how an available update should be handled.
pub const Decision = union(enum) {
    /// Show the update as available; the person chooses when.
    present,
    /// Deferral is allowed; the update waits without nagging.
    defer_allowed,
    /// Install now; either forced by a critical bound or freely permitted by good conditions.
    install_now,
    /// Held back because it would install over a metered network without consent.
    blocked_metered,
};

/// Decides how an available update should be handled.
///
/// A critical update that has been deferred to its bound installs now, because staying
/// vulnerable past that point is the greater harm; before the bound it is presented so the
/// person is pressed but not interrupted. A routine update on a metered network is blocked
/// rather than allowed to spend the person's data behind their back. Otherwise installs prefer
/// being on power — on power the update may proceed, off power it is offered but deferral stays
/// open so a low battery cannot strand a half-written system.
pub fn decide(
    severity: Severity,
    on_power: bool,
    on_metered_network: bool,
    user_deferrals: u8,
) Decision {
    // A critical fix is the one case that overrides courtesy once its bound is reached.
    if (severity == .critical and user_deferrals >= critical_defer_limit) return .install_now;

    // Spending metered data without consent is never acceptable for a routine update.
    if (severity == .routine and on_metered_network) return .blocked_metered;

    // On power and unmetered, conditions are right to install; off power, keep deferral open so
    // a dying battery cannot corrupt the write.
    if (on_power and !on_metered_network) return .install_now;

    // Security updates are pressed by being presented; routine ones simply wait.
    return switch (severity) {
        .routine => .defer_allowed,
        .security, .critical => .present,
    };
}

test "a critical update installs once it hits the deferral bound" {
    try std.testing.expectEqual(Decision.install_now, decide(.critical, false, true, critical_defer_limit));
}

test "a routine update never installs on metered network without consent" {
    try std.testing.expectEqual(Decision.blocked_metered, decide(.routine, true, true, 0));
}

test "an unmetered update on power installs now" {
    try std.testing.expectEqual(Decision.install_now, decide(.routine, true, false, 0));
}

test "a routine update off power and unmetered waits" {
    try std.testing.expectEqual(Decision.defer_allowed, decide(.routine, false, false, 1));
}

test "a security update below its urgency is presented, not forced" {
    try std.testing.expectEqual(Decision.present, decide(.security, false, false, 0));
}

test "a critical update can never be deferred past its bound, swept" {
    // The patch-liveness property: whatever the power and network conditions, once a critical
    // update reaches its deferral bound the verdict is install_now — deferral cannot outlast it.
    for ([_]bool{ false, true }) |on_power| {
        for ([_]bool{ false, true }) |metered| {
            var deferrals: u8 = critical_defer_limit;
            while (deferrals <= critical_defer_limit + 4) : (deferrals += 1) {
                try std.testing.expectEqual(Decision.install_now, decide(.critical, on_power, metered, deferrals));
            }
        }
    }
}
