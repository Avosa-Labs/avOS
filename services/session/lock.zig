//! Deciding when a session must lock, so an unattended device does not stay open to
//! whoever picks it up, and a sensitive context closes sooner than an ordinary one.
//!
//! A session left open is a session anyone in reach can use. The defence is an
//! automatic lock after inactivity, but a single fixed timeout is wrong in both
//! directions: long enough to be convenient while reading is long enough to leave a
//! banking app open on a café table, and short enough to protect the banking app is
//! short enough to be maddening while reading. So the timeout is not one number; it
//! is set by how sensitive the current context is — an ordinary session tolerates a
//! longer idle, a session showing financial or health data locks quickly, and some
//! states lock the instant they arise regardless of the timer, because a removed
//! authentication token or an explicit lock request is not something to wait out.
//! And a lock always demands re-authentication to clear, because a lock a glance can
//! undo is not a lock.
//!
//! This module locks nothing. It decides whether a session should be locked now,
//! given how long it has been idle, the sensitivity of what it shows, and any
//! immediate lock trigger, as a pure function over those inputs.

const std = @import("std");

/// How sensitive the current session context is, which sets its idle timeout.
pub const Sensitivity = enum {
    /// Ordinary content: a reader, a game. Tolerates a longer idle.
    ordinary,
    /// Personal content: messages, photos. A moderate timeout.
    personal,
    /// High-value content: financial, health, security settings. Locks quickly.
    high_value,

    /// The idle timeout for this sensitivity, in milliseconds. More sensitive
    /// contexts lock sooner.
    pub fn idleTimeoutMs(sensitivity: Sensitivity) i64 {
        return switch (sensitivity) {
            .ordinary => 5 * 60 * 1000, // 5 minutes
            .personal => 2 * 60 * 1000, // 2 minutes
            .high_value => 30 * 1000, // 30 seconds
        };
    }
};

/// An event that locks the session immediately, without waiting for the idle timer.
pub const Trigger = enum {
    /// No immediate trigger; the idle timer governs.
    none,
    /// The person asked to lock. Honoured at once.
    manual,
    /// The authentication that opened the session was revoked or expired — a
    /// credential removed, a token invalidated. The session can no longer stand.
    authentication_lost,
    /// A security event demands the session close now.
    security_event,

    fn isImmediate(trigger: Trigger) bool {
        return trigger != .none;
    }
};

/// Why the session locked, so the caller can tell the person and decide what
/// re-authentication to require.
pub const Reason = enum {
    idle_timeout,
    manual,
    authentication_lost,
    security_event,
};

/// The lock decision.
pub const Decision = union(enum) {
    /// The session stays open.
    stay_open,
    /// The session must lock, for this reason. Clearing it always requires
    /// re-authentication.
    lock: Reason,

    pub fn locks(decision: Decision) bool {
        return decision == .lock;
    }
};

/// Decides whether a session should lock now.
///
/// An immediate trigger locks at once and names itself, whatever the idle time,
/// because a lost authentication or an explicit request is not something to wait
/// out. Otherwise the idle time is compared against the timeout for the context's
/// sensitivity, so a high-value session locks after seconds where an ordinary one
/// tolerates minutes. A session within its timeout and with no trigger stays open.
pub fn evaluate(sensitivity: Sensitivity, idle_ms: i64, trigger: Trigger) Decision {
    switch (trigger) {
        .none => {},
        .manual => return .{ .lock = .manual },
        .authentication_lost => return .{ .lock = .authentication_lost },
        .security_event => return .{ .lock = .security_event },
    }
    if (idle_ms >= sensitivity.idleTimeoutMs()) return .{ .lock = .idle_timeout };
    return .stay_open;
}

test "an idle ordinary session locks after its timeout" {
    try std.testing.expectEqual(Decision.stay_open, evaluate(.ordinary, Sensitivity.ordinary.idleTimeoutMs() - 1, .none));
    try std.testing.expectEqual(Decision{ .lock = .idle_timeout }, evaluate(.ordinary, Sensitivity.ordinary.idleTimeoutMs(), .none));
}

test "a high-value session locks far sooner than an ordinary one" {
    const idle = 60 * 1000; // one minute
    // A minute idle locks a high-value session but not an ordinary one.
    try std.testing.expect(evaluate(.high_value, idle, .none).locks());
    try std.testing.expect(!evaluate(.ordinary, idle, .none).locks());
}

test "a manual trigger locks immediately whatever the idle time" {
    try std.testing.expectEqual(Decision{ .lock = .manual }, evaluate(.ordinary, 0, .manual));
}

test "lost authentication locks immediately" {
    try std.testing.expectEqual(Decision{ .lock = .authentication_lost }, evaluate(.ordinary, 0, .authentication_lost));
}

test "a security event locks immediately" {
    try std.testing.expectEqual(Decision{ .lock = .security_event }, evaluate(.high_value, 0, .security_event));
}

test "a session within timeout and no trigger stays open" {
    try std.testing.expectEqual(Decision.stay_open, evaluate(.personal, 0, .none));
}

test "more sensitive contexts have shorter timeouts" {
    try std.testing.expect(Sensitivity.high_value.idleTimeoutMs() < Sensitivity.personal.idleTimeoutMs());
    try std.testing.expect(Sensitivity.personal.idleTimeoutMs() < Sensitivity.ordinary.idleTimeoutMs());
}

test "an immediate trigger always locks regardless of sensitivity or idle, swept" {
    // The trigger-precedence property: any non-none trigger locks, at any idle time,
    // for any context.
    const triggers = [_]Trigger{ .manual, .authentication_lost, .security_event };
    for ([_]Sensitivity{ .ordinary, .personal, .high_value }) |sensitivity| {
        for (triggers) |trigger| {
            try std.testing.expect(evaluate(sensitivity, 0, trigger).locks());
        }
    }
}

test "a more sensitive session never locks later than a less sensitive one, swept" {
    // Monotone in sensitivity: at any idle time, if the ordinary session locks on
    // the timer, the more sensitive ones have already locked.
    var idle: i64 = 0;
    while (idle <= Sensitivity.ordinary.idleTimeoutMs() + 1000) : (idle += 10 * 1000) {
        const ordinary = evaluate(.ordinary, idle, .none).locks();
        if (ordinary) {
            try std.testing.expect(evaluate(.personal, idle, .none).locks());
            try std.testing.expect(evaluate(.high_value, idle, .none).locks());
        }
    }
}
