//! Deciding whether a WebSocket upgrade is allowed and whether a frame may be
//! accepted, so a long-lived socket cannot be opened by a page that should not
//! have one or used to exhaust memory a frame at a time.
//!
//! A WebSocket begins as an ordinary HTTP request that asks to be upgraded into a
//! persistent two-way channel, and that upgrade is a boundary two attacks cross.
//! The first is cross-site hijacking: a browser will happily send an upgrade
//! request from any page the person is visiting, carrying their cookies, so a
//! server that does not check where the request came from can be driven by a
//! hostile page into opening an authenticated socket on the person's behalf. The
//! defence is to check the request's origin against an allow-list at upgrade time.
//! The second is unbounded framing: a WebSocket frame declares its own length, and
//! a server that trusts that length will try to buffer whatever a peer claims,
//! which a malicious peer sets enormous. The defence is a maximum frame size, past
//! which the frame is refused and the connection closed rather than buffered.
//!
//! This module speaks no protocol and buffers no frame. It decides whether an
//! upgrade with a given origin is admitted and whether a frame of a given declared
//! size may be accepted, as pure functions over the connection's policy.

const std = @import("std");

/// Why an upgrade was refused.
pub const UpgradeRefusal = enum {
    /// The request's origin is not on the allow-list. This is the cross-site
    /// hijacking defence: an upgrade from a page that was never granted a socket
    /// is refused before the channel opens.
    origin_not_allowed,
    /// The upgrade request was missing the fields that make it a valid WebSocket
    /// handshake. A malformed handshake is refused rather than guessed at.
    malformed_handshake,
};

/// The outcome of an upgrade attempt.
pub const UpgradeDecision = union(enum) {
    accept,
    refuse: UpgradeRefusal,

    pub fn accepted(decision: UpgradeDecision) bool {
        return decision == .accept;
    }
};

/// The upgrade policy for one endpoint: which origins may open a socket to it.
pub const UpgradePolicy = struct {
    /// The origins allowed to upgrade. An empty list allows none, which is the
    /// safe default for an endpoint that has not opted anything in.
    allowed_origins: []const []const u8,

    fn allows(policy: UpgradePolicy, origin: []const u8) bool {
        for (policy.allowed_origins) |candidate| {
            if (std.mem.eql(u8, candidate, origin)) return true;
        }
        return false;
    }
};

/// A WebSocket upgrade request as the caller parsed it.
pub const UpgradeRequest = struct {
    /// The Origin the request carried. Empty when absent, which is treated as not
    /// allowed rather than waved through.
    origin: []const u8,
    /// Whether the handshake carried the required upgrade fields (the version and
    /// key). A caller sets this false for a request that only looks like an
    /// upgrade.
    well_formed: bool = true,
};

/// Decides whether an upgrade is admitted.
///
/// A malformed handshake is refused first: there is no point checking the origin
/// of a request that is not a valid upgrade. Then the origin must be on the
/// endpoint's allow-list; anything else — including a missing origin, which
/// matches nothing — is refused, so a hostile page cannot drive the person's
/// browser into opening an authenticated socket.
pub fn admitUpgrade(policy: UpgradePolicy, request: UpgradeRequest) UpgradeDecision {
    if (!request.well_formed) return .{ .refuse = .malformed_handshake };
    if (!policy.allows(request.origin)) return .{ .refuse = .origin_not_allowed };
    return .accept;
}

/// The largest frame an endpoint will accept. A frame declaring more than this is
/// refused rather than buffered, so a peer cannot force unbounded allocation.
pub const default_max_frame_bytes: u32 = 1 << 20; // 1 MiB

/// What to do with a frame of a given declared size.
pub const FrameDecision = enum {
    /// Within the size limit: accept it.
    accept,
    /// Larger than the limit: refuse it and close the connection, because a peer
    /// that oversizes a frame is either broken or hostile and buffering it is the
    /// harm.
    close,
};

/// Decides whether a frame declaring `declared_bytes` may be accepted under a
/// maximum frame size.
pub fn admitFrame(declared_bytes: u32, max_frame_bytes: u32) FrameDecision {
    return if (declared_bytes > max_frame_bytes) .close else .accept;
}

const allowed = [_][]const u8{ "https://app.example", "https://admin.example" };
const sample_policy: UpgradePolicy = .{ .allowed_origins = &allowed };

test "an upgrade from an allowed origin is accepted" {
    try std.testing.expect(admitUpgrade(sample_policy, .{ .origin = "https://app.example" }).accepted());
}

test "an upgrade from an origin not on the list is refused" {
    try std.testing.expectEqual(
        UpgradeDecision{ .refuse = .origin_not_allowed },
        admitUpgrade(sample_policy, .{ .origin = "https://evil.example" }),
    );
}

test "a missing origin is refused, not waved through" {
    // The cross-site defence must fail closed on an absent origin.
    try std.testing.expectEqual(
        UpgradeDecision{ .refuse = .origin_not_allowed },
        admitUpgrade(sample_policy, .{ .origin = "" }),
    );
}

test "a malformed handshake is refused before the origin is even checked" {
    // Even from an allowed origin, a request that is not a valid upgrade is
    // refused as malformed.
    try std.testing.expectEqual(
        UpgradeDecision{ .refuse = .malformed_handshake },
        admitUpgrade(sample_policy, .{ .origin = "https://app.example", .well_formed = false }),
    );
}

test "an empty allow-list admits no origin" {
    const closed: UpgradePolicy = .{ .allowed_origins = &.{} };
    try std.testing.expectEqual(
        UpgradeDecision{ .refuse = .origin_not_allowed },
        admitUpgrade(closed, .{ .origin = "https://app.example" }),
    );
}

test "a frame within the limit is accepted" {
    try std.testing.expectEqual(FrameDecision.accept, admitFrame(1000, default_max_frame_bytes));
    // Exactly at the limit is still accepted.
    try std.testing.expectEqual(
        FrameDecision.accept,
        admitFrame(default_max_frame_bytes, default_max_frame_bytes),
    );
}

test "an oversized frame closes the connection rather than buffering" {
    try std.testing.expectEqual(
        FrameDecision.close,
        admitFrame(default_max_frame_bytes + 1, default_max_frame_bytes),
    );
    try std.testing.expectEqual(
        FrameDecision.close,
        admitFrame(std.math.maxInt(u32), default_max_frame_bytes),
    );
}

test "only an allowed origin is ever accepted, swept" {
    // The hijacking property: across a set of candidate origins, an upgrade is
    // accepted exactly for those on the allow-list.
    const candidates = [_][]const u8{
        "https://app.example",
        "https://admin.example",
        "https://evil.example",
        "http://app.example", // scheme differs
        "",
    };
    for (candidates) |origin| {
        const decision = admitUpgrade(sample_policy, .{ .origin = origin });
        var on_list = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, a, origin)) on_list = true;
        }
        try std.testing.expectEqual(on_list, decision.accepted());
    }
}
