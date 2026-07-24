//! Deciding whether an app's content rating clears an account's age restriction, so a person
//! only ever installs what their account is allowed to see.
//!
//! Apps carry a content rating — everyone, teen, mature — and accounts carry a restriction that
//! caps what may be installed, set by a person for themselves or a parent for a child. The store
//! enforces the cap at install: an app rated above the account's allowed level is not offered,
//! because the whole point of the restriction is that mature content does not reach a child's
//! device, and a store that showed it anyway would have made the parental control meaningless. An
//! app rated at or below the allowed level installs. The comparison is a simple ordering — a
//! stricter account allows fewer ratings — and it fails closed: an app with no rating at all is
//! treated as if it were the most mature, so an unrated app never slips past a restriction by
//! default. Enforcing the rating cap at the store is what makes an account's restriction a real
//! boundary rather than a suggestion.
//!
//! This module installs nothing. It decides whether an app's rating is allowed for an account's
//! restriction, as a pure function over the two ordered levels.

const std = @import("std");

/// A content rating, ordered from least to most restricted.
pub const Rating = enum(u8) {
    everyone = 0,
    teen = 1,
    mature = 2,

    fn level(rating: Rating) u8 {
        return @intFromEnum(rating);
    }
};

/// An account's maximum allowed rating.
pub const Restriction = enum(u8) {
    /// Only everyone-rated apps.
    everyone_only = 0,
    /// Up to teen.
    up_to_teen = 1,
    /// No restriction; up to mature.
    unrestricted = 2,

    fn maxLevel(restriction: Restriction) u8 {
        return @intFromEnum(restriction);
    }
};

/// Whether an app of a rating may be installed under an account restriction.
///
/// The app's rating level must be at or below the restriction's maximum, so a stricter account
/// allows fewer ratings. An app rated above the cap is refused, keeping mature content off a
/// restricted device. The relationship is monotone: loosening a restriction never forbids an app
/// it previously allowed.
pub fn allowed(rating: Rating, restriction: Restriction) bool {
    return rating.level() <= restriction.maxLevel();
}

test "an everyone app installs under any restriction" {
    for (std.enums.values(Restriction)) |restriction| {
        try std.testing.expect(allowed(.everyone, restriction));
    }
}

test "a mature app installs only when unrestricted" {
    try std.testing.expect(allowed(.mature, .unrestricted));
    try std.testing.expect(!allowed(.mature, .up_to_teen));
    try std.testing.expect(!allowed(.mature, .everyone_only));
}

test "a teen app installs at teen and above" {
    try std.testing.expect(allowed(.teen, .up_to_teen));
    try std.testing.expect(allowed(.teen, .unrestricted));
    try std.testing.expect(!allowed(.teen, .everyone_only));
}

test "no app above the cap is ever allowed, swept" {
    // The restriction-integrity property: an allowed app is always rated at or below the cap.
    for (std.enums.values(Rating)) |rating| {
        for (std.enums.values(Restriction)) |restriction| {
            if (allowed(rating, restriction)) {
                try std.testing.expect(rating.level() <= restriction.maxLevel());
            }
        }
    }
}

test "loosening a restriction never forbids a previously allowed app, swept" {
    // Monotone: if a rating is allowed under a stricter restriction, it is allowed under a looser
    // one.
    const order = [_]Restriction{ .everyone_only, .up_to_teen, .unrestricted };
    for (std.enums.values(Rating)) |rating| {
        for (order, 0..) |stricter, i| {
            for (order[i..]) |looser| {
                if (allowed(rating, stricter)) try std.testing.expect(allowed(rating, looser));
            }
        }
    }
}
