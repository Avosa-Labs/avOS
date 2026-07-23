//! Deciding, from a probe's outcome, whether a network actually reaches the
//! internet or is holding traffic behind a login page.
//!
//! A device joining a wifi network cannot tell from the link layer whether the
//! network leads anywhere. A café or hotel network associates fine, hands out an
//! address, and then intercepts every request until a person signs in — a captive
//! portal. Software that assumes association means connectivity fails badly here:
//! it sends real requests into the interception, where they are answered with a
//! login page rather than the data asked for, and it may leak the contents of
//! those requests to whoever runs the portal. The way to know is to send one
//! request whose exact answer is known in advance to a controlled endpoint, and
//! read what actually comes back: the true answer means the internet is reachable;
//! anything else means the network is captive or dead.
//!
//! This module makes no request. It decides, given the outcome of a probe the
//! caller performed, whether the network is open, captive, or offline, and holds
//! the small state machine that keeps that verdict — including the rule that a
//! captive network is not usable for ordinary traffic until it has been cleared.

const std = @import("std");

/// The known-good endpoint returns a specific tiny response — conventionally a
/// 204 with no body. Anything else is interception.
pub const expected_status: u16 = 204;

/// What came back from a connectivity probe, as observed by the caller.
pub const ProbeOutcome = struct {
    /// Whether the probe got any HTTP response at all. False means the request
    /// timed out or the connection failed outright.
    responded: bool,
    /// The HTTP status observed, when it responded.
    status: u16 = 0,
    /// Whether the response body matched the known-expected content exactly. A
    /// portal that returns a 204 status but injects a body is still caught.
    body_matched: bool = false,
    /// Whether the probe was answered by a redirect to a different host — the
    /// commonest portal behaviour, steering the browser to a sign-in page.
    redirected: bool = false,
};

/// What a probe outcome says about the network.
pub const Connectivity = enum {
    /// The probe returned exactly what was expected: the internet is reachable.
    open,
    /// The probe was intercepted — a redirect, or the wrong status or body. A
    /// login page or similar stands between the device and the internet.
    captive,
    /// The probe got no answer at all: the network is down or leads nowhere.
    offline,

    /// Whether ordinary traffic may use a network in this state. Only an open
    /// network may; a captive one would answer with the portal, and an offline
    /// one answers with nothing.
    pub fn isUsable(connectivity: Connectivity) bool {
        return connectivity == .open;
    }
};

/// Classifies a probe outcome into a connectivity verdict.
///
/// No response at all is offline. A response that redirected, or carried the
/// wrong status, or whose body did not match the known content, is captive — the
/// body check matters because a portal can return the expected status while
/// replacing the body. Only the exact expected status with the matching body is
/// open. The default is never to treat an unexpected answer as open, so a strange
/// network is assumed captive rather than trusted.
pub fn classify(outcome: ProbeOutcome) Connectivity {
    if (!outcome.responded) return .offline;
    if (outcome.redirected) return .captive;
    if (outcome.status != expected_status) return .captive;
    if (!outcome.body_matched) return .captive;
    return .open;
}

/// The captive-portal state a caller keeps for one network, so a network known to
/// be captive stays unusable until a fresh probe confirms it has been cleared.
pub const PortalState = struct {
    connectivity: Connectivity = .offline,
    /// How many times the portal has been probed since joining. Bounds retry so a
    /// permanently captive network is not probed forever.
    probes: u32 = 0,

    /// The most probes to attempt before giving up on a network that stays
    /// captive.
    pub const max_probes: u32 = 10;

    /// Records the outcome of a probe, updating the verdict and the count.
    pub fn observe(state: *PortalState, outcome: ProbeOutcome) void {
        state.connectivity = classify(outcome);
        state.probes +|= 1;
    }

    /// Whether another probe should be attempted: only while the network is not
    /// yet open and the probe budget is not spent. An open network needs no
    /// further probing, and a persistently captive one stops being retried.
    pub fn shouldProbeAgain(state: PortalState) bool {
        return state.connectivity != .open and state.probes < max_probes;
    }

    /// Whether ordinary traffic may flow on this network right now.
    pub fn isUsable(state: PortalState) bool {
        return state.connectivity.isUsable();
    }
};

fn probeOk() ProbeOutcome {
    return .{ .responded = true, .status = expected_status, .body_matched = true };
}

test "the exact expected response is an open network" {
    try std.testing.expectEqual(Connectivity.open, classify(probeOk()));
}

test "no response is an offline network" {
    try std.testing.expectEqual(Connectivity.offline, classify(.{ .responded = false }));
}

test "a redirect is a captive network" {
    try std.testing.expectEqual(
        Connectivity.captive,
        classify(.{ .responded = true, .redirected = true }),
    );
}

test "the wrong status is a captive network" {
    try std.testing.expectEqual(
        Connectivity.captive,
        classify(.{ .responded = true, .status = 200, .body_matched = true }),
    );
}

test "the right status with an injected body is still captive" {
    // A portal that returns 204 but replaces the body is caught by the body check.
    try std.testing.expectEqual(
        Connectivity.captive,
        classify(.{ .responded = true, .status = expected_status, .body_matched = false }),
    );
}

test "only an open network is usable" {
    try std.testing.expect(Connectivity.open.isUsable());
    try std.testing.expect(!Connectivity.captive.isUsable());
    try std.testing.expect(!Connectivity.offline.isUsable());
}

test "an unexpected answer is assumed captive, never open" {
    // Fail closed: any response that is not exactly the expected one is treated as
    // interception, not trusted as connectivity.
    const outcomes = [_]ProbeOutcome{
        .{ .responded = true, .status = 302, .redirected = true },
        .{ .responded = true, .status = 200, .body_matched = false },
        .{ .responded = true, .status = 204, .body_matched = false },
        .{ .responded = true, .status = 403, .body_matched = true },
    };
    for (outcomes) |outcome| {
        try std.testing.expect(classify(outcome) != .open);
    }
}

test "observing a probe updates the verdict and counts it" {
    var state: PortalState = .{};
    state.observe(.{ .responded = true, .redirected = true });
    try std.testing.expectEqual(Connectivity.captive, state.connectivity);
    try std.testing.expectEqual(@as(u32, 1), state.probes);
    try std.testing.expect(!state.isUsable());
}

test "a captive network becomes usable once a probe confirms it cleared" {
    var state: PortalState = .{};
    state.observe(.{ .responded = true, .redirected = true });
    try std.testing.expect(!state.isUsable());
    // The person signs in; the next probe returns the expected response.
    state.observe(probeOk());
    try std.testing.expect(state.isUsable());
    // And no further probing is needed once open.
    try std.testing.expect(!state.shouldProbeAgain());
}

test "a persistently captive network stops being probed at the budget" {
    var state: PortalState = .{};
    for (0..PortalState.max_probes) |_| {
        state.observe(.{ .responded = true, .redirected = true });
    }
    // The budget is spent: give up rather than probe a hostile network forever.
    try std.testing.expect(!state.shouldProbeAgain());
    try std.testing.expect(!state.isUsable());
}

test "an offline network keeps being retried within the budget" {
    var state: PortalState = .{};
    state.observe(.{ .responded = false });
    try std.testing.expectEqual(Connectivity.offline, state.connectivity);
    try std.testing.expect(state.shouldProbeAgain());
}
