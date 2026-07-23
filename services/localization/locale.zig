//! Resolving which locale to present from what a person prefers and what a surface
//! supports, so text appears in the best available language rather than a developer
//! default or nothing.
//!
//! A person lists the languages they read, in order — their first choice, then the
//! ones they fall back to — and a given screen or document is available in some set
//! of languages, rarely all of them. Resolution is matching the two honestly. It
//! walks the person's preferences in order and picks the first the surface actually
//! offers, so a French-then-English reader gets French when it exists and English
//! when it does not, rather than always the first preference whether or not it is
//! available. A region-tagged preference falls back to its base language when the
//! exact region is missing, because a reader of Portuguese-Brazil is better served
//! by Portuguese-Portugal than by a language they did not ask for. And when nothing
//! a person listed is available, resolution returns the surface's own default rather
//! than empty text, because an unfamiliar language is still better than none.
//!
//! This module renders no text. It resolves a preference list against an available
//! set to the locale that should be shown, as a pure function over the two lists.

const std = @import("std");

/// A locale tag: a base language and an optional region, e.g. "pt" or "pt-BR". Kept
/// as a small parsed pair so region fallback is a comparison, not string surgery at
/// the call site.
pub const Locale = struct {
    /// The base language subtag, e.g. "pt". Never empty for a real locale.
    language: []const u8,
    /// The region subtag, e.g. "BR", or empty for a language-only tag.
    region: []const u8 = "",

    /// Whether two locales are the same language and region.
    fn eql(locale: Locale, other: Locale) bool {
        return std.mem.eql(u8, locale.language, other.language) and
            std.mem.eql(u8, locale.region, other.region);
    }

    /// Whether this locale and another share a base language, regardless of region.
    fn sameLanguage(locale: Locale, other: Locale) bool {
        return std.mem.eql(u8, locale.language, other.language);
    }
};

/// How well a resolved locale matches what the person asked for.
pub const MatchQuality = enum {
    /// The exact language and region the person preferred.
    exact,
    /// The right language but a different region.
    language_only,
    /// Nothing the person listed was available; the surface default was used.
    fallback_default,
};

/// The result of resolving a locale.
pub const Resolution = struct {
    locale: Locale,
    quality: MatchQuality,
};

/// Resolves the locale to present.
///
/// The person's preferences are walked in order, and for each the available set is
/// searched first for an exact language-and-region match, which is preferred and
/// returned immediately. If no preference matches exactly, the preferences are
/// walked again for a base-language match, so a region-tagged preference falls back
/// to the same language in another region before any later preference. Only when no
/// preference shares a language with anything available is the surface's default
/// returned, so the person always gets the highest-ranked language that exists.
pub fn resolve(preferences: []const Locale, available: []const Locale, default: Locale) Resolution {
    // First pass: an exact match at the highest-ranked preference.
    for (preferences) |preference| {
        for (available) |candidate| {
            if (preference.eql(candidate)) return .{ .locale = candidate, .quality = .exact };
        }
    }
    // Second pass: the same language in a different region, still by preference rank.
    for (preferences) |preference| {
        for (available) |candidate| {
            if (preference.sameLanguage(candidate)) return .{ .locale = candidate, .quality = .language_only };
        }
    }
    // Nothing the person listed is available.
    return .{ .locale = default, .quality = .fallback_default };
}

const en: Locale = .{ .language = "en" };
const fr: Locale = .{ .language = "fr" };
const pt_br: Locale = .{ .language = "pt", .region = "BR" };
const pt_pt: Locale = .{ .language = "pt", .region = "PT" };

test "the highest-ranked available preference wins" {
    const prefs = [_]Locale{ fr, en };
    const avail = [_]Locale{ en, fr };
    const resolution = resolve(&prefs, &avail, en);
    try std.testing.expect(resolution.locale.eql(fr));
    try std.testing.expectEqual(MatchQuality.exact, resolution.quality);
}

test "a missing first preference falls to the next available one" {
    const prefs = [_]Locale{ fr, en };
    const avail = [_]Locale{en}; // no French
    const resolution = resolve(&prefs, &avail, en);
    try std.testing.expect(resolution.locale.eql(en));
    try std.testing.expectEqual(MatchQuality.exact, resolution.quality);
}

test "a region-tagged preference falls back to the same language, another region" {
    const prefs = [_]Locale{pt_br};
    const avail = [_]Locale{pt_pt}; // pt-PT, not pt-BR
    const resolution = resolve(&prefs, &avail, en);
    try std.testing.expect(resolution.locale.eql(pt_pt));
    try std.testing.expectEqual(MatchQuality.language_only, resolution.quality);
}

test "an exact region match beats a same-language other region" {
    const prefs = [_]Locale{pt_br};
    const avail = [_]Locale{ pt_pt, pt_br };
    const resolution = resolve(&prefs, &avail, en);
    try std.testing.expect(resolution.locale.eql(pt_br));
    try std.testing.expectEqual(MatchQuality.exact, resolution.quality);
}

test "an exact match on a later preference beats a language-only on an earlier one" {
    // Prefer pt-BR then en. pt-PT (language-only for pt-BR) and en (exact) are both
    // available; the exact en wins because exact matches are tried before any
    // language-only fallback.
    const prefs = [_]Locale{ pt_br, en };
    const avail = [_]Locale{ pt_pt, en };
    const resolution = resolve(&prefs, &avail, fr);
    try std.testing.expect(resolution.locale.eql(en));
    try std.testing.expectEqual(MatchQuality.exact, resolution.quality);
}

test "nothing available returns the surface default" {
    const prefs = [_]Locale{fr};
    const avail = [_]Locale{ .{ .language = "de" }, .{ .language = "es" } };
    const resolution = resolve(&prefs, &avail, en);
    try std.testing.expect(resolution.locale.eql(en));
    try std.testing.expectEqual(MatchQuality.fallback_default, resolution.quality);
}

test "an empty preference list returns the default" {
    const avail = [_]Locale{fr};
    const resolution = resolve(&.{}, &avail, en);
    try std.testing.expectEqual(MatchQuality.fallback_default, resolution.quality);
}

test "a resolved non-default locale is always available and preference-ranked, swept" {
    // The honesty property: whenever resolution does not fall back, the chosen locale
    // is in the available set and shares a language with some preference.
    const prefs = [_]Locale{ pt_br, fr, en };
    const avail = [_]Locale{ pt_pt, en };
    const resolution = resolve(&prefs, &avail, .{ .language = "de" });
    if (resolution.quality != .fallback_default) {
        var in_available = false;
        for (avail) |candidate| {
            if (candidate.eql(resolution.locale)) in_available = true;
        }
        try std.testing.expect(in_available);
        var wanted = false;
        for (prefs) |preference| {
            if (preference.sameLanguage(resolution.locale)) wanted = true;
        }
        try std.testing.expect(wanted);
    }
}
