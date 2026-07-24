//! Deciding whether a virtual device snapshot may be restored, so a saved state is brought back only
//! when it is intact and belongs to a compatible device — never restored corrupt or onto the wrong
//! profile.
//!
//! A snapshot freezes a virtual device's whole state so it can be resumed later or shared to reproduce
//! a bug exactly. That only helps if the restored state is the state that was saved: a snapshot restored
//! with silent corruption resumes a device that never existed, and a bug "reproduced" from it is a
//! phantom. So restoration checks two things before resuming. The snapshot's content must match the
//! digest recorded when it was taken — a mismatch means the bytes changed in storage or transit, and
//! the snapshot is refused rather than resumed corrupt. And the snapshot's device profile must match the
//! device restoring it, because state captured on one profile — a different memory size, a different form
//! factor — does not describe a valid state of another. A snapshot that is both intact and profile-matched
//! restores; anything else is refused with the reason. Checking integrity and profile before resuming is
//! what makes a snapshot a trustworthy record of a device rather than a way to boot into an inconsistent one.
//!
//! This module restores nothing. It decides whether a snapshot may be restored, from its integrity and
//! profile match, as a pure function.

const std = @import("std");

/// A snapshot presented for restoration.
pub const Snapshot = struct {
    /// Whether the snapshot's content matches the digest recorded when it was taken.
    integrity_verified: bool,
    /// The identifier of the device profile the snapshot was captured on.
    captured_profile: u64,
};

/// Why a restore was refused.
pub const Refusal = enum {
    /// The snapshot's content does not match its recorded digest.
    corrupt,
    /// The snapshot was captured on a different device profile than the one restoring it.
    profile_mismatch,
};

/// The restore decision.
pub const Decision = union(enum) {
    restore,
    refuse: Refusal,

    pub fn restores(decision: Decision) bool {
        return decision == .restore;
    }
};

/// Decides whether a snapshot may be restored onto a device of a given profile.
///
/// Integrity is checked first: a snapshot whose content does not match its recorded digest is refused
/// as corrupt, because nothing else about it can be trusted. Then the profile must match the restoring
/// device. Only an intact, profile-matched snapshot restores; either failure refuses it with the
/// reason, so a device never resumes into a corrupt or foreign state.
pub fn decide(snapshot: Snapshot, restoring_profile: u64) Decision {
    if (!snapshot.integrity_verified) return .{ .refuse = .corrupt };
    if (snapshot.captured_profile != restoring_profile) return .{ .refuse = .profile_mismatch };
    return .restore;
}

fn makeSnapshot(intact: bool, profile: u64) Snapshot {
    return .{ .integrity_verified = intact, .captured_profile = profile };
}

test "an intact, profile-matched snapshot restores" {
    try std.testing.expect(decide(makeSnapshot(true, 7), 7).restores());
}

test "a corrupt snapshot is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .corrupt }, decide(makeSnapshot(false, 7), 7));
}

test "a snapshot from a different profile is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .profile_mismatch }, decide(makeSnapshot(true, 7), 9));
}

test "corruption is reported ahead of a profile mismatch" {
    // A corrupt snapshot that also mismatches the profile reports corruption — the deeper problem.
    try std.testing.expectEqual(Decision{ .refuse = .corrupt }, decide(makeSnapshot(false, 7), 9));
}

test "a restored snapshot is always intact and profile-matched, swept" {
    // The faithful-restore property: whenever a snapshot restores, it was verified and profile-matched.
    for ([_]bool{ false, true }) |intact| {
        for ([_]u64{ 7, 9 }) |profile| {
            if (decide(makeSnapshot(intact, profile), 7).restores()) {
                try std.testing.expect(intact);
                try std.testing.expectEqual(@as(u64, 7), profile);
            }
        }
    }
}
