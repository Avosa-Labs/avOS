//! Deciding whether the camera may capture, and requiring a visible indicator whenever it
//! does, so a camera is never recording a person without a light saying so.
//!
//! The camera is the most invasive sensor a device has, and the single rule that keeps it
//! trustworthy is not about who may use it but about what the person sees: whenever the camera
//! is capturing, a hardware-honest indicator is lit, and there is no way to capture with the
//! indicator off. That is what makes covert recording impossible rather than merely against
//! policy. So a capture is permitted only for a caller that holds camera access and only while
//! the indicator is guaranteed to show; a request that would capture without the indicator —
//! because some caller asked to suppress it — is refused, because suppressing the indicator is
//! exactly the capability an attacker wants. Access is also gated by context: a call that has
//! taken exclusive use of the camera, or a policy that disables it, blocks other captures. The
//! camera turns on with a light, or it does not turn on, and that invariant is worth more than
//! any convenience of hiding it.
//!
//! This module captures no frames. It decides whether a capture may proceed and confirms the
//! indicator is shown, as pure functions over the request context.

const std = @import("std");

/// The context a camera capture is requested in.
pub const Context = struct {
    /// Whether the caller holds camera access.
    has_access: bool,
    /// Whether the privacy indicator will be shown for this capture. Suppressing it is not
    /// allowed; a request that would suppress it is refused.
    indicator_shown: bool,
    /// Whether another exclusive user (an active call, a policy lock) is blocking the camera.
    blocked: bool,
};

/// Why a capture was refused.
pub const Refusal = enum {
    /// The caller holds no camera access.
    no_access,
    /// The capture would run without the visible indicator. Never permitted.
    indicator_suppressed,
    /// The camera is blocked by an exclusive user or policy.
    blocked,
};

/// The capture decision.
pub const Decision = union(enum) {
    capture,
    refuse: Refusal,

    pub fn captures(decision: Decision) bool {
        return decision == .capture;
    }
};

/// Decides whether a camera capture may proceed.
///
/// The caller must hold access, the indicator must be shown, and the camera must not be blocked
/// — all three. The indicator requirement is absolute: a capture that would run without the
/// visible indicator is refused, so there is no path to covert recording. Only a capture that
/// is authorized, visibly indicated, and unblocked proceeds.
pub fn decide(context: Context) Decision {
    if (!context.has_access) return .{ .refuse = .no_access };
    if (!context.indicator_shown) return .{ .refuse = .indicator_suppressed };
    if (context.blocked) return .{ .refuse = .blocked };
    return .capture;
}

fn ctx(access: bool, indicator: bool, blocked: bool) Context {
    return .{ .has_access = access, .indicator_shown = indicator, .blocked = blocked };
}

test "an authorized, indicated, unblocked capture proceeds" {
    try std.testing.expect(decide(ctx(true, true, false)).captures());
}

test "a capture without access is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .no_access }, decide(ctx(false, true, false)));
}

test "a capture without the indicator is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .indicator_suppressed }, decide(ctx(true, false, false)));
}

test "a blocked camera refuses capture" {
    try std.testing.expectEqual(Decision{ .refuse = .blocked }, decide(ctx(true, true, true)));
}

test "no capture ever runs without the indicator, swept" {
    // The no-covert-recording property: whenever a capture proceeds, the indicator is shown.
    for ([_]bool{ false, true }) |access| {
        for ([_]bool{ false, true }) |indicator| {
            for ([_]bool{ false, true }) |blocked| {
                if (decide(ctx(access, indicator, blocked)).captures()) {
                    try std.testing.expect(indicator);
                }
            }
        }
    }
}
