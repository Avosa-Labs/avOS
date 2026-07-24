//! Deciding what the spatial form factor may do, so glasses or a headset can present and approve in
//! the person's field of view without carrying installation authority.
//!
//! A spatial surface — glasses, a headset — places the session directly in the person's vision. It is
//! personal and can be trusted with sensitive content, and because it is worn by the owner it may
//! approve a consequential action with a look or a gesture, the kind of immediate confirmation spatial
//! interaction is good at. But like the wearable it is not an installation surface: choosing and
//! installing software is a deliberate, text-and-detail task poorly suited to a heads-up display, and
//! placing installation authority in glasses invites exactly the kind of glance-and-confirm mistake
//! that installing software must never be. So the spatial form factor presents, acts, and approves,
//! and does not install. This is the platform's device-not-identity rule again: the owner who installs
//! from a phone cannot install through glasses, because the glasses are not where that authority lives.
//! Granting spatial the power to approve while withholding the power to install is what keeps an
//! immersive surface useful without making it a channel for consequential software changes.
//!
//! This module renders nothing. It decides which interactions the spatial form factor permits, as a
//! pure function.

const std = @import("std");

/// An interaction an endpoint might permit.
pub const Interaction = enum { present, act, approve, install };

/// Whether the spatial form factor permits an interaction.
///
/// It presents, acts, and approves — the in-view confirmations spatial interaction suits — but does
/// not install, keeping installation authority off a glance-and-gesture surface.
pub fn permits(interaction: Interaction) bool {
    return switch (interaction) {
        .present, .act, .approve => true,
        .install => false,
    };
}

/// Whether the spatial surface may present sensitive content unmasked. It may — it is in the owner's
/// private field of view.
pub fn showsSensitive() bool {
    return true;
}

test "the spatial surface may present, act, and approve" {
    try std.testing.expect(permits(.present));
    try std.testing.expect(permits(.act));
    try std.testing.expect(permits(.approve));
}

test "the spatial surface may not install" {
    try std.testing.expect(!permits(.install));
}

test "the spatial surface never permits installation, swept" {
    // The glasses-approve-without-install property from the platform's endpoint-capability rule.
    for (std.enums.values(Interaction)) |interaction| {
        if (permits(interaction)) {
            try std.testing.expect(interaction != .install);
        }
    }
}
