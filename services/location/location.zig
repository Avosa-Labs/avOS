//! Deciding at what precision a caller may read location, and whether it may read
//! it in the background, so an app gets the least location that serves its purpose
//! and never more than the person granted.
//!
//! Location is among the most revealing things a device knows: precise, continuous
//! location is a record of where a person lives, works, worships, and sleeps. So
//! access to it is not a yes-or-no permission but a graded one, and the grading is
//! what keeps a grant proportionate. An app that needs only the city for weather
//! must not receive the doorstep; an app granted foreground access must not quietly
//! track a person while it is closed. The service therefore hands back the coarsest
//! location that satisfies the request within the grant — never finer than granted,
//! never in the background unless that was allowed — so a broad ask against a narrow
//! grant yields the narrow answer rather than a refusal or an over-share.
//!
//! This module reads no GPS. It decides the precision a request resolves to and
//! whether a background read is permitted, as pure functions over the grant and the
//! request, so the least-privilege answer is computed in one place.

const std = @import("std");

/// How precise a location fix is, ordered from least to most revealing so a grant
/// can cap a request by comparison.
pub const Precision = enum(u8) {
    /// No location at all.
    none = 0,
    /// Coarse: city or neighbourhood scale. Enough for weather, a regional feed.
    approximate = 1,
    /// Fine: street-and-doorstep scale. Needed for navigation, ride pickup.
    precise = 2,

    fn atMost(precision: Precision, cap: Precision) Precision {
        return if (@intFromEnum(precision) <= @intFromEnum(cap)) precision else cap;
    }
};

/// What a caller was granted: the finest precision it may receive and whether it
/// may read location while not in the foreground.
pub const Grant = struct {
    precision: Precision,
    /// Whether the caller may read location in the background. Foreground-only is
    /// the safer default: an app tracks only while a person is using it.
    allow_background: bool = false,
};

/// A location request.
pub const Request = struct {
    /// The finest precision the caller is asking for. The service returns this or
    /// the grant's cap, whichever is coarser.
    wants: Precision,
    /// Whether the caller is currently in the background.
    in_background: bool,
};

/// Why a location read was refused.
pub const Refusal = enum {
    /// The caller holds no location grant at all.
    not_granted,
    /// The caller is in the background and was not granted background access.
    background_not_allowed,
};

/// The outcome of a location request.
pub const Decision = union(enum) {
    /// The read may proceed at this precision — the coarsest that satisfies the
    /// request within the grant.
    provide: Precision,
    /// The read is refused.
    refuse: Refusal,

    pub fn provided(decision: Decision) bool {
        return decision == .provide;
    }
};

/// Decides the precision a request resolves to.
///
/// A caller with no location grant is refused. A background caller without
/// background access is refused, so a foreground-only grant cannot be turned into
/// tracking. Otherwise the read proceeds at the coarser of what was asked and what
/// was granted — never finer than the grant, and no finer than needed — so a broad
/// request against a narrow grant returns the narrow precision rather than an
/// over-share or a refusal.
pub fn locate(grant: Grant, request: Request) Decision {
    if (grant.precision == .none) return .{ .refuse = .not_granted };
    if (request.in_background and !grant.allow_background) {
        return .{ .refuse = .background_not_allowed };
    }
    return .{ .provide = request.wants.atMost(grant.precision) };
}

fn makeRequest(wants: Precision, in_background: bool) Request {
    return .{ .wants = wants, .in_background = in_background };
}

test "a precise grant serves a precise foreground request" {
    const grant: Grant = .{ .precision = .precise, .allow_background = false };
    try std.testing.expectEqual(Decision{ .provide = .precise }, locate(grant, makeRequest(.precise, false)));
}

test "a precise request against an approximate grant is downgraded, not refused" {
    // The least-privilege answer: the narrow grant caps the broad ask.
    const grant: Grant = .{ .precision = .approximate };
    try std.testing.expectEqual(Decision{ .provide = .approximate }, locate(grant, makeRequest(.precise, false)));
}

test "an approximate request against a precise grant stays approximate" {
    // No more than needed: asking for coarse location yields coarse even when finer
    // is granted.
    const grant: Grant = .{ .precision = .precise };
    try std.testing.expectEqual(Decision{ .provide = .approximate }, locate(grant, makeRequest(.approximate, false)));
}

test "no grant is refused" {
    const grant: Grant = .{ .precision = .none };
    try std.testing.expectEqual(Decision{ .refuse = .not_granted }, locate(grant, makeRequest(.precise, false)));
}

test "a background request without background access is refused" {
    const grant: Grant = .{ .precision = .precise, .allow_background = false };
    try std.testing.expectEqual(Decision{ .refuse = .background_not_allowed }, locate(grant, makeRequest(.precise, true)));
}

test "a background request with background access is served" {
    const grant: Grant = .{ .precision = .precise, .allow_background = true };
    try std.testing.expectEqual(Decision{ .provide = .precise }, locate(grant, makeRequest(.precise, true)));
}

test "a provided precision is never finer than the grant, swept" {
    // The core property: whatever the request, an accepted read never exceeds the
    // granted precision.
    const grants = [_]Precision{ .approximate, .precise };
    const wants = [_]Precision{ .none, .approximate, .precise };
    for (grants) |granted| {
        for (wants) |w| {
            for ([_]bool{ false, true }) |bg| {
                const grant: Grant = .{ .precision = granted, .allow_background = true };
                const decision = locate(grant, makeRequest(w, bg));
                switch (decision) {
                    .provide => |p| try std.testing.expect(@intFromEnum(p) <= @intFromEnum(granted)),
                    .refuse => {},
                }
            }
        }
    }
}

test "a foreground-only grant never serves the background, swept" {
    // A foreground-only grant cannot be turned into background tracking, whatever
    // the requested precision.
    const grant: Grant = .{ .precision = .precise, .allow_background = false };
    for ([_]Precision{ .approximate, .precise }) |w| {
        try std.testing.expect(!locate(grant, makeRequest(w, true)).provided());
    }
}
