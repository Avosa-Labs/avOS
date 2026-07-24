//! Deciding whether a locked note's content is shown, so the note a person locked stays sealed until
//! they authenticate — even to someone holding the unlocked device.
//!
//! A person locks a note precisely because unlocking the device is not enough protection for it: a
//! journal, a list of passwords, something private on a device family members or a partner also use
//! unlocked. The lock is a second wall, and it means something only if it holds when the device is
//! already open. So a locked note reveals its content only against a fresh authentication for that
//! note; without it the content stays withheld and the note shows as locked, no matter that the
//! device itself is unlocked. An unlocked note, by contrast, is shown normally — it was never put
//! behind the wall. Anchoring the reveal to a per-note authentication rather than to the device's
//! unlocked state is what makes a locked note actually private on a shared or briefly-borrowed
//! device, which is the situation the person locked it for.
//!
//! This module renders no note. It decides whether a note's content may be shown, from whether the
//! note is locked and whether it was freshly authenticated, as a pure function.

const std = @import("std");

/// A note's protection state.
pub const Note = enum {
    /// An ordinary note, shown whenever the device is unlocked.
    unlocked,
    /// A note the person locked, sealed behind its own authentication.
    locked,
};

/// Whether a note's content may be shown.
///
/// An unlocked note shows. A locked note shows only when a fresh authentication for it was provided;
/// otherwise its content stays withheld even on an unlocked device, so the second wall the person put
/// up holds against anyone who did not clear it.
pub fn mayShow(note: Note, authenticated: bool) bool {
    return switch (note) {
        .unlocked => true,
        .locked => authenticated,
    };
}

test "an unlocked note is shown" {
    try std.testing.expect(mayShow(.unlocked, false));
}

test "a locked note is withheld until authenticated" {
    try std.testing.expect(!mayShow(.locked, false));
    try std.testing.expect(mayShow(.locked, true));
}

test "locked content is shown only under authentication, swept" {
    // The sealed-note property: a shown locked note was freshly authenticated.
    for ([_]bool{ false, true }) |authenticated| {
        if (mayShow(.locked, authenticated)) {
            try std.testing.expect(authenticated);
        }
    }
}
