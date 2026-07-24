//! Recognizing an emergency number as it is dialed, so a call for help is routed as an
//! emergency however the person reached the dialer and whatever network they are on.
//!
//! The single most important number a phone can dial is the one for help, and recognizing it
//! is a safety function, not a lookup. The recognition has to be generous in the right ways.
//! Emergency numbers differ by country — 911, 112, 999, 000, and more — and a person may be
//! travelling, so the dialer recognizes the emergency numbers for the network's country and
//! the well-known international ones, not just the home country's, because someone in trouble
//! abroad dials what they know or what is posted locally. Recognition must also see through
//! the noise a dialer collects: spaces, dashes, and a leading pause make no difference to
//! whether a number is 112. And it errs toward recognizing: treating a genuine emergency
//! number as ordinary is a catastrophe, while treating a lookalike as emergency merely routes
//! a call specially. So the recognizer normalizes the dialed digits and checks them against
//! the emergency set for the person's context, and a match routes the call as an emergency.
//!
//! This module dials nothing. It decides whether a dialed string is an emergency number for a
//! network country, after normalizing it, as a pure function.

const std = @import("std");

/// The internationally-recognized emergency numbers that are treated as emergency everywhere,
/// regardless of the network's country, because they are widely posted and dialed by
/// travellers.
pub const universal_numbers = [_][]const u8{ "112", "911" };

/// One country's emergency numbers.
pub const CountryEmergency = struct {
    /// The ISO country code, e.g. "GB".
    country: []const u8,
    /// The emergency numbers for that country.
    numbers: []const []const u8,
};

/// A small table of country emergency numbers. Real deployments carry the full set; the
/// recognition rule is the same however large the table.
pub const country_table = [_]CountryEmergency{
    .{ .country = "US", .numbers = &.{"911"} },
    .{ .country = "GB", .numbers = &.{"999"} },
    .{ .country = "AU", .numbers = &.{"000"} },
    .{ .country = "EU", .numbers = &.{"112"} },
};

/// Normalizes a dialed string into bare digits, stripping the spaces, dashes, and other
/// formatting a dialer collects, into `buffer`. Returns the digit slice.
pub fn normalize(dialed: []const u8, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (dialed) |ch| {
        if (ch >= '0' and ch <= '9') {
            if (len < buffer.len) {
                buffer[len] = ch;
                len += 1;
            }
        }
    }
    return buffer[0..len];
}

/// Whether the normalized digits match any number in a set.
fn matchesAny(digits: []const u8, numbers: []const []const u8) bool {
    for (numbers) |number| {
        if (std.mem.eql(u8, digits, number)) return true;
    }
    return false;
}

/// Whether a dialed string is an emergency number for the given network country.
///
/// The dialed string is normalized to bare digits first, so formatting never hides an
/// emergency number. It is recognized if it matches a universal emergency number — treated as
/// emergency everywhere for travellers — or an emergency number for the network's country.
/// Matching either set routes the call as an emergency.
pub fn isEmergency(dialed: []const u8, network_country: []const u8) bool {
    var buffer: [32]u8 = undefined;
    const digits = normalize(dialed, &buffer);
    if (digits.len == 0) return false;
    if (matchesAny(digits, &universal_numbers)) return true;
    for (country_table) |entry| {
        if (std.mem.eql(u8, entry.country, network_country)) {
            return matchesAny(digits, entry.numbers);
        }
    }
    return false;
}

test "a universal emergency number is recognized in any country" {
    try std.testing.expect(isEmergency("112", "US"));
    try std.testing.expect(isEmergency("911", "GB"));
}

test "a country-specific emergency number is recognized on that network" {
    try std.testing.expect(isEmergency("999", "GB"));
    try std.testing.expect(isEmergency("000", "AU"));
}

test "formatting is stripped before matching" {
    try std.testing.expect(isEmergency("9-1-1", "US"));
    try std.testing.expect(isEmergency(" 1 1 2 ", "EU"));
}

test "an ordinary number is not emergency" {
    try std.testing.expect(!isEmergency("5551234", "US"));
    try std.testing.expect(!isEmergency("", "US"));
}

test "a country-specific number is not recognized on a foreign network unless universal" {
    // 999 is GB-specific and not universal; on a US network it is not emergency.
    try std.testing.expect(!isEmergency("999", "US"));
}

test "every universal number is recognized on every country, swept" {
    // The traveller-safety property: 112 and 911 are emergency on any network.
    const countries = [_][]const u8{ "US", "GB", "AU", "EU", "ZZ" };
    for (universal_numbers) |number| {
        for (countries) |country| {
            try std.testing.expect(isEmergency(number, country));
        }
    }
}

test "normalization keeps only digits" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("112", normalize("+1-1-2 (abc)", &buf));
}
