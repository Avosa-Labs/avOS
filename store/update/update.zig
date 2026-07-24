//! Deciding whether an app update may replace the installed version, so an update comes only from
//! the same developer, never downgrades, and never ships without passing review.
//!
//! An update is the most trusted operation a store performs, because it replaces code already on a
//! person's device, often automatically, with the device's existing trust in the app carried over.
//! That trust is exactly what an attacker wants to hijack, so three invariants guard it. The
//! update must be signed by the same developer as the installed app — a different signer is not an
//! update, it is a takeover, and letting one app's identity be seized by another key is the worst
//! failure a store can have. The version must not go backward — a downgrade reintroduces the flaws
//! a newer version fixed and is a known attack path — so an update must be strictly newer than what
//! is installed. And the update build must itself have passed review, because an update is new code
//! and gets no free pass on the strength of the old version's approval. An update that holds all
//! three replaces the installed app; any that fails is refused, keeping the auto-update channel
//! from becoming an attack channel.
//!
//! This module updates nothing. It decides whether an update may replace the installed app, from
//! the signer, the versions, and the review status, as a pure function.

const std = @import("std");

/// An update presented against the installed app.
pub const Update = struct {
    /// Whether the update is signed by the same developer key as the installed app.
    same_signer: bool,
    /// The installed version.
    installed_version: u32,
    /// The update's version.
    update_version: u32,
    /// Whether the update build passed review.
    reviewed: bool,
};

/// Why an update was refused.
pub const Refusal = enum {
    /// The update is signed by a different developer: a takeover attempt.
    signer_changed,
    /// The update is not newer than the installed version: a downgrade.
    downgrade,
    /// The update build has not passed review.
    unreviewed,
};

/// The update decision.
pub const Decision = union(enum) {
    apply,
    refuse: Refusal,

    pub fn applies(decision: Decision) bool {
        return decision == .apply;
    }
};

/// Decides whether an update may replace the installed app.
///
/// The signer is checked first, because a different signer means the update is not from the app's
/// developer and must never be applied whatever else it offers. Then the version must be strictly
/// greater than the installed one, refusing a downgrade. Then the update must have passed review,
/// because new code earns no trust from the old version's approval. All three must hold to apply.
pub fn decide(update: Update) Decision {
    if (!update.same_signer) return .{ .refuse = .signer_changed };
    if (update.update_version <= update.installed_version) return .{ .refuse = .downgrade };
    if (!update.reviewed) return .{ .refuse = .unreviewed };
    return .apply;
}

fn makeUpdate(same_signer: bool, installed: u32, version: u32, reviewed: bool) Update {
    return .{ .same_signer = same_signer, .installed_version = installed, .update_version = version, .reviewed = reviewed };
}

test "a same-signer, newer, reviewed update applies" {
    try std.testing.expect(decide(makeUpdate(true, 3, 4, true)).applies());
}

test "a different signer is refused as a takeover" {
    try std.testing.expectEqual(Decision{ .refuse = .signer_changed }, decide(makeUpdate(false, 3, 4, true)));
}

test "a downgrade is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .downgrade }, decide(makeUpdate(true, 4, 3, true)));
    // The same version is not newer, so it is a downgrade too.
    try std.testing.expectEqual(Decision{ .refuse = .downgrade }, decide(makeUpdate(true, 4, 4, true)));
}

test "an unreviewed update is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .unreviewed }, decide(makeUpdate(true, 3, 4, false)));
}

test "the signer check precedes the others" {
    // A different-signer downgrade reports the signer change, the more serious problem.
    try std.testing.expectEqual(Decision{ .refuse = .signer_changed }, decide(makeUpdate(false, 4, 3, false)));
}

test "no update from a different signer ever applies, swept" {
    // The no-takeover property: an applied update always has the same signer.
    for ([_]bool{ false, true }) |same_signer| {
        for ([_]bool{ false, true }) |reviewed| {
            if (decide(makeUpdate(same_signer, 1, 2, reviewed)).applies()) {
                try std.testing.expect(same_signer);
            }
        }
    }
}

test "no update ever downgrades, swept" {
    // The no-downgrade property: an applied update is always strictly newer than installed.
    var version: u32 = 0;
    while (version <= 5) : (version += 1) {
        if (decide(makeUpdate(true, 3, version, true)).applies()) {
            try std.testing.expect(version > 3);
        }
    }
}
