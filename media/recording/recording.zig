//! Deciding whether a recording may proceed, requiring a visible indicator and space to store
//! it, so nothing records a person covertly or starts a capture it cannot save.
//!
//! Recording — audio or video — captures a person and the world around them, and like the
//! camera its trustworthiness rests on visibility: whenever a recording is running, an indicator
//! shows it, and there is no way to record with the indicator off. That is what makes covert
//! recording impossible rather than merely discouraged, so a request that would suppress the
//! indicator is refused outright. Beyond visibility, a recording must have somewhere to go: a
//! capture started with no room to store it fills what little space remains and then fails
//! partway, losing the recording and leaving the device wedged, so a recording is admitted only
//! when there is storage for at least a meaningful amount of it. And the caller must hold
//! recording access. Access, a shown indicator, and available storage — a recording proceeds
//! only when all three hold, which keeps capture both honest and reliable.
//!
//! This module records nothing. It decides whether a recording may start, from access, the
//! indicator, and available storage, as a pure function.

const std = @import("std");

/// The minimum free storage, in bytes, required to start a recording — enough for a meaningful
/// capture rather than a few seconds before the disk fills.
pub const min_storage_bytes: u64 = 64 * 1024 * 1024; // 64 MB

/// The context a recording is requested in.
pub const Context = struct {
    /// Whether the caller holds recording access.
    has_access: bool,
    /// Whether the recording indicator will be shown. Suppressing it is never allowed.
    indicator_shown: bool,
    /// Free storage available, in bytes.
    storage_available_bytes: u64,
};

/// Why a recording was refused.
pub const Refusal = enum {
    /// The caller holds no recording access.
    no_access,
    /// The recording would run without the visible indicator. Never permitted.
    indicator_suppressed,
    /// Not enough storage to hold a meaningful recording.
    insufficient_storage,
};

/// The recording decision.
pub const Decision = union(enum) {
    record,
    refuse: Refusal,

    pub fn records(decision: Decision) bool {
        return decision == .record;
    }
};

/// Decides whether a recording may start.
///
/// The caller must hold access, the indicator must be shown, and there must be enough storage —
/// all three. The indicator requirement is absolute: a recording that would run without it is
/// refused, so there is no covert-capture path. A recording with too little storage is refused
/// before it starts, rather than failing partway and losing what it captured.
pub fn decide(context: Context) Decision {
    if (!context.has_access) return .{ .refuse = .no_access };
    if (!context.indicator_shown) return .{ .refuse = .indicator_suppressed };
    if (context.storage_available_bytes < min_storage_bytes) return .{ .refuse = .insufficient_storage };
    return .record;
}

fn ctx(access: bool, indicator: bool, storage: u64) Context {
    return .{ .has_access = access, .indicator_shown = indicator, .storage_available_bytes = storage };
}

const plenty: u64 = 1 << 30;

test "an authorized, indicated recording with storage proceeds" {
    try std.testing.expect(decide(ctx(true, true, plenty)).records());
}

test "recording without access is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .no_access }, decide(ctx(false, true, plenty)));
}

test "recording without the indicator is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .indicator_suppressed }, decide(ctx(true, false, plenty)));
}

test "recording without storage is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .insufficient_storage }, decide(ctx(true, true, 1024)));
}

test "the storage threshold is inclusive" {
    try std.testing.expect(decide(ctx(true, true, min_storage_bytes)).records());
    try std.testing.expect(!decide(ctx(true, true, min_storage_bytes - 1)).records());
}

test "no recording ever runs without the indicator, swept" {
    // The no-covert-capture property: whenever a recording proceeds, the indicator is shown.
    for ([_]bool{ false, true }) |access| {
        for ([_]bool{ false, true }) |indicator| {
            for ([_]u64{ 0, plenty }) |storage| {
                if (decide(ctx(access, indicator, storage)).records()) {
                    try std.testing.expect(indicator);
                }
            }
        }
    }
}
