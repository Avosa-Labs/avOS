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

/// The emergency numbers each country recognizes, by ISO 3166-1 alpha-2 code. Every
/// number a country routes as an emergency — police, fire, ambulance, and any general
/// line — is listed, so a match on any of them recognizes the call. The universal
/// numbers above are recognized everywhere in addition to these, so a country that also
/// uses 112 or 911 need not repeat it here (though several do where it is the primary).
///
/// The recognition rule does not change with the table's size; the table is the coverage.
pub const country_table = [_]CountryEmergency{
    // --- Europe (112 is the common EU number; national lines are listed alongside it) ---
    .{ .country = "AL", .numbers = &.{ "112", "129", "128", "127" } },
    .{ .country = "AD", .numbers = &.{ "112", "110", "118" } },
    .{ .country = "AT", .numbers = &.{ "112", "133", "122", "144" } },
    .{ .country = "BY", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "BE", .numbers = &.{ "112", "101", "100" } },
    .{ .country = "BA", .numbers = &.{ "112", "122", "123", "124" } },
    .{ .country = "BG", .numbers = &.{ "112", "166", "160", "150" } },
    .{ .country = "HR", .numbers = &.{ "112", "192", "193", "194" } },
    .{ .country = "CY", .numbers = &.{ "112", "199" } },
    .{ .country = "CZ", .numbers = &.{ "112", "158", "150", "155" } },
    .{ .country = "DK", .numbers = &.{ "112", "114" } },
    .{ .country = "EE", .numbers = &.{ "112", "110" } },
    .{ .country = "FI", .numbers = &.{"112"} },
    .{ .country = "FR", .numbers = &.{ "112", "17", "18", "15", "114" } },
    .{ .country = "DE", .numbers = &.{ "112", "110" } },
    .{ .country = "GR", .numbers = &.{ "112", "100", "199", "166" } },
    .{ .country = "HU", .numbers = &.{ "112", "107", "105", "104" } },
    .{ .country = "IS", .numbers = &.{"112"} },
    .{ .country = "IE", .numbers = &.{ "112", "999" } },
    .{ .country = "IT", .numbers = &.{ "112", "113", "115", "118" } },
    .{ .country = "XK", .numbers = &.{ "112", "192", "193", "194" } },
    .{ .country = "LV", .numbers = &.{ "112", "110", "101", "103" } },
    .{ .country = "LI", .numbers = &.{ "112", "117", "118", "144" } },
    .{ .country = "LT", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "LU", .numbers = &.{ "112", "113" } },
    .{ .country = "MT", .numbers = &.{"112"} },
    .{ .country = "MD", .numbers = &.{ "112", "902", "901", "903" } },
    .{ .country = "MC", .numbers = &.{ "112", "17", "18", "15" } },
    .{ .country = "ME", .numbers = &.{ "112", "122", "123", "124" } },
    .{ .country = "NL", .numbers = &.{"112"} },
    .{ .country = "MK", .numbers = &.{ "112", "192", "193", "194" } },
    .{ .country = "NO", .numbers = &.{ "112", "110", "113" } },
    .{ .country = "PL", .numbers = &.{ "112", "997", "998", "999" } },
    .{ .country = "PT", .numbers = &.{"112"} },
    .{ .country = "RO", .numbers = &.{"112"} },
    .{ .country = "RU", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "SM", .numbers = &.{ "112", "113" } },
    .{ .country = "RS", .numbers = &.{ "112", "192", "193", "194" } },
    .{ .country = "SK", .numbers = &.{ "112", "158", "150", "155" } },
    .{ .country = "SI", .numbers = &.{ "112", "113" } },
    .{ .country = "ES", .numbers = &.{ "112", "091", "080", "061" } },
    .{ .country = "SE", .numbers = &.{ "112", "114" } },
    .{ .country = "CH", .numbers = &.{ "112", "117", "118", "144" } },
    .{ .country = "UA", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "GB", .numbers = &.{ "999", "112" } },
    .{ .country = "VA", .numbers = &.{ "112", "113" } },

    // --- Americas (911 is common across North and much of Latin America) ---
    .{ .country = "AG", .numbers = &.{ "911", "999" } },
    .{ .country = "AR", .numbers = &.{ "911", "101", "100", "107" } },
    .{ .country = "BS", .numbers = &.{ "911", "919" } },
    .{ .country = "BB", .numbers = &.{ "911", "211", "311", "511" } },
    .{ .country = "BZ", .numbers = &.{ "911", "90" } },
    .{ .country = "BO", .numbers = &.{ "911", "110", "118", "119" } },
    .{ .country = "BR", .numbers = &.{ "190", "192", "193", "911", "112" } },
    .{ .country = "CA", .numbers = &.{"911"} },
    .{ .country = "CL", .numbers = &.{ "133", "132", "131", "112" } },
    .{ .country = "CO", .numbers = &.{ "123", "112", "156" } },
    .{ .country = "CR", .numbers = &.{"911"} },
    .{ .country = "CU", .numbers = &.{ "106", "105", "104" } },
    .{ .country = "DM", .numbers = &.{ "911", "999" } },
    .{ .country = "DO", .numbers = &.{"911"} },
    .{ .country = "EC", .numbers = &.{"911"} },
    .{ .country = "SV", .numbers = &.{"911"} },
    .{ .country = "GD", .numbers = &.{ "911", "434" } },
    .{ .country = "GT", .numbers = &.{ "110", "120", "122", "911" } },
    .{ .country = "GY", .numbers = &.{ "911", "912", "913" } },
    .{ .country = "HT", .numbers = &.{ "114", "118" } },
    .{ .country = "HN", .numbers = &.{ "911", "199" } },
    .{ .country = "JM", .numbers = &.{ "119", "110" } },
    .{ .country = "MX", .numbers = &.{"911"} },
    .{ .country = "NI", .numbers = &.{ "911", "118" } },
    .{ .country = "PA", .numbers = &.{ "911", "104", "103" } },
    .{ .country = "PY", .numbers = &.{ "911", "912" } },
    .{ .country = "PE", .numbers = &.{ "105", "116", "106", "911" } },
    .{ .country = "KN", .numbers = &.{ "911", "999" } },
    .{ .country = "LC", .numbers = &.{ "911", "999" } },
    .{ .country = "VC", .numbers = &.{ "911", "999" } },
    .{ .country = "SR", .numbers = &.{ "115", "110" } },
    .{ .country = "TT", .numbers = &.{ "999", "990", "811" } },
    .{ .country = "US", .numbers = &.{"911"} },
    .{ .country = "UY", .numbers = &.{ "911", "128", "104", "108" } },
    .{ .country = "VE", .numbers = &.{ "911", "171" } },

    // --- Asia ---
    .{ .country = "AF", .numbers = &.{ "119", "112", "102" } },
    .{ .country = "AM", .numbers = &.{ "112", "911", "102", "101", "103" } },
    .{ .country = "AZ", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "BH", .numbers = &.{ "999", "112" } },
    .{ .country = "BD", .numbers = &.{"999"} },
    .{ .country = "BT", .numbers = &.{ "113", "110", "112" } },
    .{ .country = "BN", .numbers = &.{ "993", "995", "991" } },
    .{ .country = "KH", .numbers = &.{ "117", "118", "119" } },
    .{ .country = "CN", .numbers = &.{ "110", "119", "120", "122", "112" } },
    .{ .country = "GE", .numbers = &.{"112"} },
    .{ .country = "HK", .numbers = &.{ "999", "112" } },
    .{ .country = "IN", .numbers = &.{ "112", "100", "101", "102", "108" } },
    .{ .country = "ID", .numbers = &.{ "112", "110", "113", "118", "119" } },
    .{ .country = "IR", .numbers = &.{ "110", "125", "115" } },
    .{ .country = "IQ", .numbers = &.{ "104", "115", "112" } },
    .{ .country = "IL", .numbers = &.{ "100", "102", "101", "112" } },
    .{ .country = "JP", .numbers = &.{ "110", "119" } },
    .{ .country = "JO", .numbers = &.{ "911", "191", "199" } },
    .{ .country = "KZ", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "KW", .numbers = &.{ "112", "777" } },
    .{ .country = "KG", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "LA", .numbers = &.{ "191", "190", "195" } },
    .{ .country = "LB", .numbers = &.{ "112", "175", "140" } },
    .{ .country = "MO", .numbers = &.{ "999", "110", "112" } },
    .{ .country = "MY", .numbers = &.{ "999", "112", "994", "991" } },
    .{ .country = "MV", .numbers = &.{ "119", "118", "102" } },
    .{ .country = "MN", .numbers = &.{ "105", "102", "103", "108" } },
    .{ .country = "MM", .numbers = &.{ "199", "191", "192" } },
    .{ .country = "NP", .numbers = &.{ "100", "101", "102", "112" } },
    .{ .country = "OM", .numbers = &.{ "9999", "112" } },
    .{ .country = "PK", .numbers = &.{ "15", "16", "115", "1122", "112" } },
    .{ .country = "PS", .numbers = &.{ "100", "101", "102" } },
    .{ .country = "PH", .numbers = &.{"911"} },
    .{ .country = "QA", .numbers = &.{ "999", "112" } },
    .{ .country = "SA", .numbers = &.{ "999", "998", "997", "993", "911" } },
    .{ .country = "SG", .numbers = &.{ "999", "995" } },
    .{ .country = "KR", .numbers = &.{ "112", "119" } },
    .{ .country = "LK", .numbers = &.{ "119", "110", "1990" } },
    .{ .country = "SY", .numbers = &.{ "112", "113", "110" } },
    .{ .country = "TW", .numbers = &.{ "110", "119", "112" } },
    .{ .country = "TJ", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "TH", .numbers = &.{ "191", "199", "1669", "112" } },
    .{ .country = "TL", .numbers = &.{ "112", "110", "115" } },
    .{ .country = "TR", .numbers = &.{"112"} },
    .{ .country = "TM", .numbers = &.{ "112", "02", "01", "03" } },
    .{ .country = "AE", .numbers = &.{ "999", "997", "998", "112" } },
    .{ .country = "UZ", .numbers = &.{ "112", "102", "101", "103" } },
    .{ .country = "VN", .numbers = &.{ "113", "114", "115" } },
    .{ .country = "YE", .numbers = &.{ "191", "199" } },

    // --- Africa ---
    .{ .country = "DZ", .numbers = &.{ "17", "14", "112" } },
    .{ .country = "AO", .numbers = &.{ "113", "115", "116" } },
    .{ .country = "BJ", .numbers = &.{ "117", "118" } },
    .{ .country = "BW", .numbers = &.{ "999", "997", "998", "911" } },
    .{ .country = "BF", .numbers = &.{ "17", "18" } },
    .{ .country = "BI", .numbers = &.{ "117", "112" } },
    .{ .country = "CM", .numbers = &.{ "117", "118", "119" } },
    .{ .country = "CV", .numbers = &.{ "132", "131", "130" } },
    .{ .country = "CF", .numbers = &.{"117"} },
    .{ .country = "TD", .numbers = &.{ "17", "18" } },
    .{ .country = "KM", .numbers = &.{"17"} },
    .{ .country = "CG", .numbers = &.{"117"} },
    .{ .country = "CD", .numbers = &.{ "112", "113" } },
    .{ .country = "CI", .numbers = &.{ "111", "180", "185", "170" } },
    .{ .country = "DJ", .numbers = &.{ "17", "18" } },
    .{ .country = "EG", .numbers = &.{ "122", "180", "123" } },
    .{ .country = "GQ", .numbers = &.{ "114", "115" } },
    .{ .country = "ER", .numbers = &.{"113"} },
    .{ .country = "SZ", .numbers = &.{ "999", "933" } },
    .{ .country = "ET", .numbers = &.{ "991", "939", "907" } },
    .{ .country = "GA", .numbers = &.{ "1730", "18" } },
    .{ .country = "GM", .numbers = &.{ "117", "116", "118" } },
    .{ .country = "GH", .numbers = &.{ "191", "192", "193", "999", "112" } },
    .{ .country = "GN", .numbers = &.{"117"} },
    .{ .country = "GW", .numbers = &.{"121"} },
    .{ .country = "KE", .numbers = &.{ "999", "112", "911" } },
    .{ .country = "LS", .numbers = &.{ "123", "121", "122" } },
    .{ .country = "LR", .numbers = &.{ "911", "355" } },
    .{ .country = "LY", .numbers = &.{ "1515", "193" } },
    .{ .country = "MG", .numbers = &.{ "117", "118", "124" } },
    .{ .country = "MW", .numbers = &.{ "997", "998", "999" } },
    .{ .country = "ML", .numbers = &.{ "17", "18", "15" } },
    .{ .country = "MR", .numbers = &.{ "117", "118" } },
    .{ .country = "MU", .numbers = &.{ "999", "112", "114", "115" } },
    .{ .country = "MA", .numbers = &.{ "19", "15", "112" } },
    .{ .country = "MZ", .numbers = &.{ "119", "198" } },
    .{ .country = "NA", .numbers = &.{ "10111", "112" } },
    .{ .country = "NE", .numbers = &.{ "17", "18" } },
    .{ .country = "NG", .numbers = &.{ "112", "199", "911" } },
    .{ .country = "RW", .numbers = &.{ "112", "111", "912" } },
    .{ .country = "ST", .numbers = &.{ "112", "113" } },
    .{ .country = "SN", .numbers = &.{ "17", "18" } },
    .{ .country = "SC", .numbers = &.{ "999", "112" } },
    .{ .country = "SL", .numbers = &.{ "019", "999" } },
    .{ .country = "SO", .numbers = &.{ "888", "999" } },
    .{ .country = "ZA", .numbers = &.{ "10111", "10177", "112" } },
    .{ .country = "SS", .numbers = &.{"999"} },
    .{ .country = "SD", .numbers = &.{ "999", "333" } },
    .{ .country = "TZ", .numbers = &.{ "112", "111", "114", "115" } },
    .{ .country = "TG", .numbers = &.{ "117", "118" } },
    .{ .country = "TN", .numbers = &.{ "197", "198", "190", "112" } },
    .{ .country = "UG", .numbers = &.{ "999", "112" } },
    .{ .country = "ZM", .numbers = &.{ "999", "991", "993" } },
    .{ .country = "ZW", .numbers = &.{ "999", "995", "993", "112" } },

    // --- Oceania ---
    .{ .country = "AU", .numbers = &.{ "000", "112", "106" } },
    .{ .country = "FJ", .numbers = &.{ "911", "917", "910" } },
    .{ .country = "KI", .numbers = &.{ "999", "992", "994" } },
    .{ .country = "MH", .numbers = &.{"911"} },
    .{ .country = "FM", .numbers = &.{"911"} },
    .{ .country = "NR", .numbers = &.{ "110", "111", "112" } },
    .{ .country = "NZ", .numbers = &.{ "111", "112" } },
    .{ .country = "PW", .numbers = &.{"911"} },
    .{ .country = "PG", .numbers = &.{ "000", "111", "112" } },
    .{ .country = "WS", .numbers = &.{ "911", "994", "999" } },
    .{ .country = "SB", .numbers = &.{ "999", "911" } },
    .{ .country = "TO", .numbers = &.{ "911", "922", "933" } },
    .{ .country = "TV", .numbers = &.{ "911", "999" } },
    .{ .country = "VU", .numbers = &.{ "112", "111" } },
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

test "country-specific numbers are recognized across regions" {
    // A spread across continents, each dialing what is posted locally.
    try std.testing.expect(isEmergency("110", "JP")); // Japan police
    try std.testing.expect(isEmergency("119", "KR")); // Korea fire/ambulance
    try std.testing.expect(isEmergency("100", "IN")); // India police
    try std.testing.expect(isEmergency("17", "FR")); // France police
    try std.testing.expect(isEmergency("111", "NZ")); // New Zealand
    try std.testing.expect(isEmergency("10111", "ZA")); // South Africa police
    try std.testing.expect(isEmergency("999", "SG")); // Singapore police
    try std.testing.expect(isEmergency("998", "AE")); // UAE ambulance
    try std.testing.expect(isEmergency("133", "CL")); // Chile police
}

test "a local number is not emergency on a foreign network unless universal" {
    // Japan's 110 is not emergency on a US network; the US universal 911 still is.
    try std.testing.expect(!isEmergency("110", "US"));
    try std.testing.expect(isEmergency("911", "JP"));
}

test "the table covers the world, not a handful of countries" {
    // The point of the fix: broad coverage, so a traveller's network country is likely
    // present. Every entry must also carry at least one number.
    try std.testing.expect(country_table.len >= 150);
    for (country_table) |entry| {
        try std.testing.expect(entry.country.len == 2);
        try std.testing.expect(entry.numbers.len >= 1);
    }
}

test "every country's own numbers are recognized on its network, swept" {
    // The coverage property: for each country, each listed number is emergency there.
    for (country_table) |entry| {
        for (entry.numbers) |number| {
            try std.testing.expect(isEmergency(number, entry.country));
        }
    }
}
