//! Deciding how the desktop form factor presents the session, so a windowed, pointer-driven surface
//! offers precise multitasking while keeping the same authority a private handset has.
//!
//! A desktop is a private surface with a keyboard, a precise pointer, and a large display that invites
//! many windows at once. Its adaptation over the phone is about interaction precision and window
//! management, not authority: it keeps the full interaction set — present, act, approve, install — and
//! shows sensitive content, because it is still a personal surface one person sits at, and it adds
//! pointer-precision input and free window placement that a touch handset cannot offer. As on the
//! tablet, the added capabilities are how the person works, not what the endpoint may do; a pointer
//! that can click a single pixel does not grant any authority a finger tap lacks. Keeping the desktop's
//! authority identical to the phone's while widening its interaction affordances is what lets the same
//! session feel native at a desk without the desk becoming a more powerful place to act than the pocket.
//!
//! This module manages no window. It decides the desktop's permitted interactions, its sensitive-
//! content trust, and whether pointer-precision input is available, as pure functions.

const std = @import("std");

/// An interaction an endpoint might permit.
pub const Interaction = enum { present, act, approve, install };

/// Whether the desktop form factor permits an interaction. It permits the full set.
pub fn permits(interaction: Interaction) bool {
    return switch (interaction) {
        .present, .act, .approve, .install => true,
    };
}

/// Whether the desktop may present sensitive content unmasked. It may — a private personal surface.
pub fn showsSensitive() bool {
    return true;
}

/// Whether pointer-precision input (fine cursor, hover, right-click) is available.
///
/// It is: the desktop's defining input affordance. This is an interaction capability the desktop has
/// and a touch-only phone does not, and it changes how the person works without changing what they may
/// authorize.
pub fn hasPointerPrecision() bool {
    return true;
}

test "the desktop permits the full interaction set" {
    for (std.enums.values(Interaction)) |interaction| {
        try std.testing.expect(permits(interaction));
    }
}

test "the desktop shows sensitive content and offers pointer precision" {
    try std.testing.expect(showsSensitive());
    try std.testing.expect(hasPointerPrecision());
}
