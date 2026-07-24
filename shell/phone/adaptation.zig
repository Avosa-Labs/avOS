//! Deciding how the phone form factor presents the session, so the handset — the reference endpoint
//! — offers the full interaction surface while still obeying the rule that capabilities belong to the
//! device, not to the identity that arrived on it.
//!
//! The phone is the baseline the other form factors are measured against: a private, handheld, single-
//! person surface with a touchscreen, trusted with sensitive content because it is normally in one
//! person's hand. So the phone permits the whole interaction set — presenting, acting, approving, and
//! installing — and shows sensitive content without masking. But even the reference form factor is
//! subject to the governing principle of session portability: what an endpoint can do is a property of
//! the endpoint, not something inherited from the person's instance. The phone permits these
//! interactions because a phone is capable of and appropriate for them, not because the identity that
//! moved onto it was powerful elsewhere. Stating the phone's full surface explicitly is what makes the
//! other form factors' restrictions legible as deliberate reductions from a known baseline rather than
//! arbitrary limits.
//!
//! This module renders nothing. It decides which interactions the phone form factor permits and
//! whether it may show sensitive content, as pure functions.

const std = @import("std");

/// An interaction an endpoint might permit.
pub const Interaction = enum {
    /// Render the session.
    present,
    /// Send input — act as the person.
    act,
    /// Authorize a consequential action.
    approve,
    /// Install applications.
    install,
};

/// Whether the phone form factor permits an interaction.
///
/// The phone permits every interaction: it is the private handheld surface the platform treats as the
/// full-capability reference. The other form factors define themselves by which of these they remove.
pub fn permits(interaction: Interaction) bool {
    return switch (interaction) {
        .present, .act, .approve, .install => true,
    };
}

/// Whether the phone may present sensitive content unmasked.
///
/// It may: a handset is normally in one person's hand, the trust assumption the whole form factor
/// rests on. Surfaces that are not private — a room display, a vehicle — withdraw exactly this.
pub fn showsSensitive() bool {
    return true;
}

test "the phone permits the full interaction set" {
    for (std.enums.values(Interaction)) |interaction| {
        try std.testing.expect(permits(interaction));
    }
}

test "the phone shows sensitive content" {
    try std.testing.expect(showsSensitive());
}
