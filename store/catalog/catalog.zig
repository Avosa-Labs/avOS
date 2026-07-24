//! Deciding whether an app appears in the store catalogue, so search and browse show only apps
//! that are approved, present, and available to this person.
//!
//! The catalogue is what a person searches and browses, and it must show exactly the apps they
//! could install and no others. An app appears only if it has been approved by review — an app
//! still in review or rejected is not a product yet. It must not have been removed — a pulled app
//! is gone from the shelves, not merely un-installable. And it must be available to this person:
//! available in their region and within their account's content restriction, because listing an
//! app a person cannot get, or that their parental controls forbid, is at best a dead end and at
//! worst shows a child something they should not see. Filtering the catalogue by all of these at
//! once means the storefront a person sees is honest — everything in it is something they can
//! actually install — which is the difference between a catalogue and a wall of unavailable
//! listings.
//!
//! This module lists nothing. It decides whether an app is visible in the catalogue for a person,
//! as a pure function over the app's status and the person's context.

const std = @import("std");

/// An app's catalogue-relevant status and the viewing context.
pub const Listing = struct {
    /// Whether the app passed review and is approved.
    approved: bool,
    /// Whether the app has been removed from the store.
    removed: bool,
    /// Whether the app is available in the viewer's region.
    available_in_region: bool,
    /// Whether the app's rating is within the viewer's account restriction.
    within_rating: bool,
};

/// Whether an app is visible in the catalogue.
///
/// The app must be approved, not removed, available in the viewer's region, and within their
/// rating restriction — all four. Any one failing hides the listing, so the catalogue never shows
/// an app the person cannot install, has been pulled, is unavailable where they are, or is above
/// their content restriction.
pub fn visible(listing: Listing) bool {
    return listing.approved and
        !listing.removed and
        listing.available_in_region and
        listing.within_rating;
}

fn makeListing(approved: bool, removed: bool, region: bool, rating: bool) Listing {
    return .{ .approved = approved, .removed = removed, .available_in_region = region, .within_rating = rating };
}

test "an approved, present, available, rating-appropriate app is visible" {
    try std.testing.expect(visible(makeListing(true, false, true, true)));
}

test "an unapproved app is hidden" {
    try std.testing.expect(!visible(makeListing(false, false, true, true)));
}

test "a removed app is hidden" {
    try std.testing.expect(!visible(makeListing(true, true, true, true)));
}

test "an app unavailable in the region is hidden" {
    try std.testing.expect(!visible(makeListing(true, false, false, true)));
}

test "an app above the rating restriction is hidden" {
    try std.testing.expect(!visible(makeListing(true, false, true, false)));
}

test "a visible app always satisfies every condition, swept" {
    // The honest-catalogue property: a visible app is approved, present, available, and within
    // rating.
    for ([_]bool{ false, true }) |approved| {
        for ([_]bool{ false, true }) |removed| {
            for ([_]bool{ false, true }) |region| {
                for ([_]bool{ false, true }) |rating| {
                    if (visible(makeListing(approved, removed, region, rating))) {
                        try std.testing.expect(approved and !removed and region and rating);
                    }
                }
            }
        }
    }
}
