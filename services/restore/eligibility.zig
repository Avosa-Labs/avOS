//! Deciding whether a backup may be offered as a restore, so a person is only ever
//! shown a backup that will actually apply to this device and told plainly when one
//! will overwrite data.
//!
//! Restore is offered at delicate moments — setting up a new device, recovering a
//! broken one — and offering the wrong backup is worse than offering none. A backup
//! written by a newer version of the system than this device runs cannot be applied,
//! and presenting it as a choice only leads to a failed restore after the person has
//! committed to it. A backup for a different account is not this person's to restore.
//! And a restore onto a device that already holds data is destructive in a way a
//! restore onto a fresh one is not, so the two are not the same offer: the fresh-device
//! restore proceeds, while the one that would overwrite existing data is offered only
//! with an explicit confirmation, because replacing what is already there is a choice
//! the person must make knowingly. The cryptographic verification of the backup's
//! contents happens below this; here is the question of whether to offer it at all.
//!
//! This module restores nothing. It decides offer, offer-with-confirmation, or refuse
//! from the backup's compatibility and the device's state, as a pure function.

const std = @import("std");

/// What is known about a candidate backup and the device it would restore to.
pub const Candidate = struct {
    /// The system version the backup was written by.
    backup_version: u32,
    /// The system version this device runs. A backup newer than this cannot apply.
    device_version: u32,
    /// The account the backup belongs to.
    backup_account: u32,
    /// The account requesting the restore.
    requesting_account: u32,
    /// Whether the device already holds user data that a restore would overwrite.
    device_has_data: bool,
};

/// Why a backup was not offered.
pub const Refusal = enum {
    /// The backup was written by a newer system than this device runs, so it cannot
    /// be applied.
    newer_than_device,
    /// The backup belongs to a different account than the one requesting it.
    wrong_account,
};

/// The eligibility decision.
pub const Decision = union(enum) {
    /// The backup may be restored directly.
    offer,
    /// The backup may be restored, but it would overwrite existing data, so the
    /// person must confirm first.
    offer_with_confirmation,
    /// The backup is not eligible and is not offered.
    refuse: Refusal,

    pub fn offered(decision: Decision) bool {
        return decision == .offer or decision == .offer_with_confirmation;
    }
};

/// Decides whether a backup may be offered as a restore.
///
/// The hard eligibility checks come first: a backup newer than the device cannot be
/// applied, and a backup for another account is not the requester's to restore —
/// either refuses outright. Past those, a restore onto a fresh device is offered
/// directly, while a restore that would overwrite existing data is offered only with
/// an explicit confirmation, so nothing already on the device is replaced without the
/// person choosing it knowingly.
pub fn decide(candidate: Candidate) Decision {
    if (candidate.backup_version > candidate.device_version) return .{ .refuse = .newer_than_device };
    if (candidate.backup_account != candidate.requesting_account) return .{ .refuse = .wrong_account };
    if (candidate.device_has_data) return .offer_with_confirmation;
    return .offer;
}

fn makeCandidate(bv: u32, dv: u32, ba: u32, ra: u32, has_data: bool) Candidate {
    return .{
        .backup_version = bv,
        .device_version = dv,
        .backup_account = ba,
        .requesting_account = ra,
        .device_has_data = has_data,
    };
}

test "a compatible backup onto a fresh device is offered directly" {
    try std.testing.expectEqual(Decision.offer, decide(makeCandidate(2, 3, 1, 1, false)));
}

test "a restore that would overwrite data needs confirmation" {
    try std.testing.expectEqual(Decision.offer_with_confirmation, decide(makeCandidate(2, 3, 1, 1, true)));
}

test "a backup newer than the device is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .newer_than_device }, decide(makeCandidate(4, 3, 1, 1, false)));
}

test "the same version restores" {
    try std.testing.expect(decide(makeCandidate(3, 3, 1, 1, false)).offered());
}

test "a backup for another account is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .wrong_account }, decide(makeCandidate(2, 3, 1, 2, false)));
}

test "compatibility is checked before the account" {
    // A newer backup for the wrong account reports the version problem, which makes
    // it inapplicable regardless of ownership.
    try std.testing.expectEqual(Decision{ .refuse = .newer_than_device }, decide(makeCandidate(4, 3, 1, 2, false)));
}

test "an offer over existing data is always the confirmation variant, swept" {
    // The no-silent-overwrite property: whenever a device with data is offered a
    // restore, it is the confirmation variant, never a bare offer.
    for ([_]bool{ false, true }) |has_data| {
        const decision = decide(makeCandidate(2, 3, 1, 1, has_data));
        if (decision.offered() and has_data) {
            try std.testing.expectEqual(Decision.offer_with_confirmation, decision);
        }
    }
}

test "an ineligible backup is never offered, swept" {
    // A newer-than-device or wrong-account backup is never offered, whatever the
    // device data state.
    for ([_]bool{ false, true }) |has_data| {
        try std.testing.expect(!decide(makeCandidate(4, 3, 1, 1, has_data)).offered());
        try std.testing.expect(!decide(makeCandidate(2, 3, 1, 2, has_data)).offered());
    }
}
