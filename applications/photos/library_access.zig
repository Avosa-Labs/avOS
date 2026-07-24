//! Deciding which photos an app may see, so granting an app "a photo" gives it that photo and not
//! the whole library.
//!
//! The usual photo prompt is all-or-nothing: an app that needs one picture to set an avatar asks
//! for the library and gets every photo the person has ever taken. That is a vast over-grant — a
//! years-long record of places, faces, and private moments handed over for a single upload. So
//! access here is per-item by default: the person picks the specific photos an app may read, and the
//! app sees those and nothing else, not even that other photos exist. A full-library grant is still
//! possible for the rare app that genuinely manages the whole collection, but it is a distinct,
//! explicit choice rather than the price of sharing one image. Scoping to the person's selection
//! means the blast radius of a compromised or overreaching app is the handful of photos they chose,
//! not their entire history.
//!
//! This module opens no photo. It decides whether an app may read a specific photo, from the grant
//! kind and whether that photo is in the person's selection, as a pure function.

const std = @import("std");

/// What the person granted an app over their photo library.
pub const Grant = union(enum) {
    /// No access.
    none,
    /// Access limited to the photos the person explicitly selected, identified by id.
    selected: []const u64,
    /// Access to the entire library, granted as a distinct explicit choice.
    full,
};

/// Whether one of the selected ids matches the requested photo.
fn inSelection(selection: []const u64, photo_id: u64) bool {
    for (selection) |id| {
        if (id == photo_id) return true;
    }
    return false;
}

/// Whether an app with a given grant may read a specific photo.
///
/// No grant reads nothing. A selected grant reads only the photos whose ids the person chose. A full
/// grant reads any photo. The default path is the selected one, so an app ordinarily sees exactly
/// the photos the person handed it and cannot enumerate or read the rest of the library.
pub fn mayRead(grant: Grant, photo_id: u64) bool {
    return switch (grant) {
        .none => false,
        .selected => |selection| inSelection(selection, photo_id),
        .full => true,
    };
}

test "no grant reads no photo" {
    try std.testing.expect(!mayRead(.none, 7));
}

test "a selected grant reads only the chosen photos" {
    const grant = Grant{ .selected = &.{ 3, 7, 9 } };
    try std.testing.expect(mayRead(grant, 7));
    try std.testing.expect(!mayRead(grant, 8));
}

test "a full grant reads any photo" {
    try std.testing.expect(mayRead(.full, 42));
}

test "a selected grant never reads outside the selection, swept" {
    // The per-item property: under a selected grant, a readable photo was one the person chose.
    const selection = [_]u64{ 3, 7, 9 };
    const grant = Grant{ .selected = &selection };
    var photo_id: u64 = 0;
    while (photo_id < 12) : (photo_id += 1) {
        if (mayRead(grant, photo_id)) {
            try std.testing.expect(inSelection(&selection, photo_id));
        }
    }
}
