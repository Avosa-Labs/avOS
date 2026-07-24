//! Deciding how the tablet form factor presents the session, so a larger private canvas can show
//! several surfaces at once without changing what the endpoint is trusted to do.
//!
//! A tablet is a phone's trust model on a bigger sheet of glass: still a private, personal surface
//! normally in one person's hands, but with room to present more than one thing at a time. So it keeps
//! the phone's full interaction set — present, act, approve, install — and its willingness to show
//! sensitive content, and adds one thing the phone's size denies it: side-by-side presentation of
//! multiple surfaces. The extra capability is a presentation affordance, not an authority change; a
//! bigger screen lets a person see two tasks together but does not make the endpoint able to do
//! anything a phone could not. Drawing the line there keeps the platform honest about the difference
//! between what a form factor can *show* and what it may *do* — the tablet expands the former and
//! leaves the latter exactly where the phone set it.
//!
//! This module lays out nothing. It decides the tablet's permitted interactions, its sensitive-content
//! trust, and how many surfaces it may present at once, as pure functions.

const std = @import("std");

/// An interaction an endpoint might permit.
pub const Interaction = enum { present, act, approve, install };

/// The maximum number of surfaces the tablet presents side by side.
pub const max_simultaneous_surfaces: u8 = 3;

/// Whether the tablet form factor permits an interaction. It permits the full set, like the phone.
pub fn permits(interaction: Interaction) bool {
    return switch (interaction) {
        .present, .act, .approve, .install => true,
    };
}

/// Whether the tablet may present sensitive content unmasked. It may — it is a private surface.
pub fn showsSensitive() bool {
    return true;
}

/// Whether the tablet may present a given number of surfaces at once.
///
/// It may present up to its simultaneous-surface limit — the affordance a larger canvas grants over a
/// phone. A request beyond the limit is refused, so layout stays legible rather than crowding surfaces
/// past usefulness.
pub fn mayPresentCount(count: u8) bool {
    return count >= 1 and count <= max_simultaneous_surfaces;
}

test "the tablet permits the full interaction set" {
    for (std.enums.values(Interaction)) |interaction| {
        try std.testing.expect(permits(interaction));
    }
}

test "the tablet shows sensitive content" {
    try std.testing.expect(showsSensitive());
}

test "the tablet presents up to its surface limit and no more" {
    try std.testing.expect(mayPresentCount(1));
    try std.testing.expect(mayPresentCount(max_simultaneous_surfaces));
    try std.testing.expect(!mayPresentCount(max_simultaneous_surfaces + 1));
    try std.testing.expect(!mayPresentCount(0));
}
