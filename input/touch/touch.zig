//! Classifying a touch contact, so a palm resting on the screen is ignored and a
//! deliberate tap is told apart from the start of a drag.
//!
//! A touchscreen reports every contact, and most of the work of making touch feel right
//! is deciding which contacts are intentional and what a person meant by them. A palm or
//! a knuckle laid on the screen registers as a large contact, and if the system treats it
//! as a finger it fires taps a person never made — the reason a phone in a pocket or a
//! hand cradling a tablet does things on its own. So a contact whose area is too large to
//! be a fingertip is rejected as a palm. Among the real fingertip contacts, a tap and a
//! drag begin identically — a finger touches down — and are only distinguished by what
//! happens next: a contact that lifts quickly without moving far is a tap, while one that
//! moves past a small threshold becomes a drag. Getting these two classifications right is
//! most of what separates a screen that responds to intent from one that responds to every
//! accident.
//!
//! This module reads no digitizer. It classifies a contact as palm or fingertip and a
//! fingertip motion as a tap or a drag, as pure functions over the contact's measurements.

const std = @import("std");

/// The largest contact area, in square millimetres, still treated as a fingertip. A
/// contact larger than this is a palm or a knuckle and is rejected.
pub const max_fingertip_area_mm2: u32 = 120;

/// The distance, in tenths of a millimetre, a fingertip may move and still count as a tap
/// rather than the beginning of a drag.
pub const tap_slop_tenths_mm: u32 = 30; // 3 mm

/// The longest a contact may last, in milliseconds, and still be a tap rather than a hold.
pub const tap_max_duration_ms: i64 = 300;

/// A touch contact's measurements.
pub const Contact = struct {
    /// The contact patch area in square millimetres.
    area_mm2: u32,
    /// How far the contact moved from touchdown, in tenths of a millimetre.
    moved_tenths_mm: u32,
    /// How long the contact lasted, in milliseconds.
    duration_ms: i64,
};

/// Whether a contact is a fingertip (small enough) rather than a palm.
pub fn isFingertip(contact: Contact) bool {
    return contact.area_mm2 <= max_fingertip_area_mm2;
}

/// What a fingertip contact resolves to.
pub const Gesture = enum {
    /// A quick, near-stationary touch: a tap.
    tap,
    /// A stationary touch held past the tap duration: a press-and-hold.
    hold,
    /// A touch that moved past the slop threshold: the start of a drag.
    drag,
    /// The contact is a palm and is ignored entirely.
    rejected,
};

/// Classifies a contact into a gesture.
///
/// A contact too large to be a fingertip is rejected as a palm before anything else, so a
/// palm never produces a tap. A fingertip that moved past the slop threshold is a drag,
/// whatever its timing, because movement is the clearest signal of intent to drag. A
/// near-stationary fingertip is a tap if it was brief and a hold if it lingered past the
/// tap duration. The movement check precedes the timing check, so a slow drag is a drag,
/// not a hold.
pub fn classify(contact: Contact) Gesture {
    if (!isFingertip(contact)) return .rejected;
    if (contact.moved_tenths_mm > tap_slop_tenths_mm) return .drag;
    if (contact.duration_ms > tap_max_duration_ms) return .hold;
    return .tap;
}

fn makeContact(area: u32, moved: u32, duration: i64) Contact {
    return .{ .area_mm2 = area, .moved_tenths_mm = moved, .duration_ms = duration };
}

test "a small brief stationary contact is a tap" {
    try std.testing.expectEqual(Gesture.tap, classify(makeContact(30, 0, 100)));
}

test "a palm-sized contact is rejected" {
    try std.testing.expectEqual(Gesture.rejected, classify(makeContact(300, 0, 100)));
}

test "a fingertip that moves is a drag" {
    try std.testing.expectEqual(Gesture.drag, classify(makeContact(30, 100, 500)));
}

test "a stationary contact held long is a hold" {
    try std.testing.expectEqual(Gesture.hold, classify(makeContact(30, 0, 500)));
}

test "movement takes precedence over duration: a slow drag is a drag" {
    // Moved past slop and held long: it is a drag, not a hold.
    try std.testing.expectEqual(Gesture.drag, classify(makeContact(30, 100, 1000)));
}

test "the fingertip area boundary is inclusive" {
    try std.testing.expect(isFingertip(makeContact(max_fingertip_area_mm2, 0, 0)));
    try std.testing.expect(!isFingertip(makeContact(max_fingertip_area_mm2 + 1, 0, 0)));
}

test "the tap slop boundary distinguishes tap from drag" {
    try std.testing.expectEqual(Gesture.tap, classify(makeContact(30, tap_slop_tenths_mm, 100)));
    try std.testing.expectEqual(Gesture.drag, classify(makeContact(30, tap_slop_tenths_mm + 1, 100)));
}

test "no palm ever produces an intentional gesture, swept" {
    // The palm-rejection property: any contact over the fingertip area is rejected,
    // whatever its motion or duration.
    var moved: u32 = 0;
    while (moved <= 200) : (moved += 50) {
        const c = makeContact(max_fingertip_area_mm2 + 50, moved, 200);
        try std.testing.expectEqual(Gesture.rejected, classify(c));
    }
}
