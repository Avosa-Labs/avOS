//! Choosing which language to show a message in, and falling back when it is
//! missing rather than showing nothing.
//!
//! A message a person cannot read is a failure, and the way software usually
//! reaches it is not by having no translation but by having an incomplete one:
//! a locale that covers most of the interface and, for the one string nobody
//! translated, shows a blank, a key name, or a crash. So the rule here is that
//! there is always an answer. A message is looked up in the requested locale;
//! if it is missing there, in that locale's base language; and if missing there
//! too, in the platform's source language, which every message is guaranteed to
//! have. The person always sees words, in the closest language available, and a
//! caller can tell which fallback was taken so a missing translation is
//! measurable rather than silent.
//!
//! It formats no numbers and parses no grammar; it resolves which string to
//! show. Plural selection is included because it is where a naive catalog most
//! often produces "1 items", and getting it wrong reads as broken even when
//! every word is translated.

const std = @import("std");

/// A locale identifier: a language and an optional region.
///
/// Compared by exact match first, then by language alone, which is what makes
/// the fallback from a region to its base language work.
pub const Locale = struct {
    /// A two- or three-letter language code, lowercase.
    language: []const u8,
    /// An optional region code, uppercase, or empty for none.
    region: []const u8 = "",

    pub fn eql(a: Locale, b: Locale) bool {
        return std.mem.eql(u8, a.language, b.language) and std.mem.eql(u8, a.region, b.region);
    }

    /// Whether two locales share a language, ignoring region. A regional string
    /// falls back to a same-language one before crossing languages.
    pub fn sameLanguage(a: Locale, b: Locale) bool {
        return std.mem.eql(u8, a.language, b.language);
    }
};

/// The source language every message is guaranteed to exist in.
///
/// The final fallback, so a lookup never fails. It is the language the platform
/// is authored in, and a message with no source entry is a build-time bug, not
/// a runtime miss.
pub const source_locale: Locale = .{ .language = "en" };

/// The plural category a count falls into.
///
/// A small, language-independent set that covers the cases the platform's
/// languages need. A catalog entry provides a string per category it uses, and
/// the source language always provides `one` and `other`.
pub const Plural = enum {
    zero,
    one,
    other,

    /// The category a count falls into under the common English-like rule.
    ///
    /// Exactly one is `one`; zero is its own category so "no items" can read
    /// differently from "2 items"; everything else is `other`. A locale whose
    /// rule differs supplies its own selector; this is the default.
    pub fn forCount(count: u64) Plural {
        return switch (count) {
            0 => .zero,
            1 => .one,
            else => .other,
        };
    }
};

/// One translatable message: a key and its string in one locale.
pub const Entry = struct {
    key: []const u8,
    locale: Locale,
    /// The plural category this entry serves, for a plural message. A
    /// non-plural message uses `.other` and is looked up with a count that
    /// resolves there.
    plural: Plural = .other,
    text: []const u8,
};

/// Which language a resolved message actually came from.
///
/// Returned alongside the text so a caller can tell an exact hit from a
/// fallback, which is what makes a missing translation measurable instead of
/// invisible.
pub const Source = enum {
    /// Found in the exact requested locale.
    exact,
    /// Found in the requested language but not its region.
    language_fallback,
    /// Found only in the source language.
    source_fallback,
};

/// A resolved message.
pub const Resolution = struct {
    text: []const u8,
    source: Source,
};

/// A catalog of entries, searched in fallback order.
///
/// The entries are borrowed, not owned; a real catalog loads them from a
/// resource, and this is the lookup over whatever set it holds.
pub const Catalog = struct {
    entries: []const Entry,

    /// Resolves a message for a locale and count.
    ///
    /// Tries the exact locale, then the same language without region, then the
    /// source language. Because the source language always has the key, this
    /// never returns null for a key the build includes — a fact the caller can
    /// rely on rather than handling an absent message everywhere.
    pub fn resolve(
        catalog: Catalog,
        key: []const u8,
        locale: Locale,
        count: u64,
    ) ?Resolution {
        const plural = Plural.forCount(count);

        if (catalog.find(key, locale, plural, .exact)) |exact| return exact;
        if (catalog.find(key, locale, plural, .language)) |language| return language;
        if (catalog.findSource(key, plural)) |source| return source;

        // A key present in no locale at all is a missing string; the caller gets
        // null and can surface the key rather than a blank.
        return null;
    }

    const Match = enum { exact, language };

    fn find(catalog: Catalog, key: []const u8, locale: Locale, plural: Plural, match: Match) ?Resolution {
        // Try the requested plural, then fall back to `other`, because a locale
        // may translate the common case and leave a rarer plural to the general
        // form rather than omitting the message.
        for ([_]Plural{ plural, .other }) |wanted| {
            for (catalog.entries) |entry| {
                if (!std.mem.eql(u8, entry.key, key)) continue;
                if (entry.plural != wanted) continue;
                const hit = switch (match) {
                    .exact => entry.locale.eql(locale),
                    .language => entry.locale.sameLanguage(locale) and !entry.locale.eql(locale),
                };
                if (hit) return .{
                    .text = entry.text,
                    .source = if (match == .exact) .exact else .language_fallback,
                };
            }
        }
        return null;
    }

    fn findSource(catalog: Catalog, key: []const u8, plural: Plural) ?Resolution {
        for ([_]Plural{ plural, .other }) |wanted| {
            for (catalog.entries) |entry| {
                if (!std.mem.eql(u8, entry.key, key)) continue;
                if (entry.plural != wanted) continue;
                if (entry.locale.eql(source_locale)) {
                    return .{ .text = entry.text, .source = .source_fallback };
                }
            }
        }
        return null;
    }
};

const en: Locale = .{ .language = "en" };
const en_gb: Locale = .{ .language = "en", .region = "GB" };
const fr: Locale = .{ .language = "fr" };
const fr_ca: Locale = .{ .language = "fr", .region = "CA" };

const sample = [_]Entry{
    .{ .key = "greeting", .locale = en, .text = "Hello" },
    .{ .key = "greeting", .locale = fr, .text = "Bonjour" },
    .{ .key = "greeting", .locale = fr_ca, .text = "Allo" },
    .{ .key = "colour", .locale = en, .text = "color" },
    .{ .key = "colour", .locale = en_gb, .text = "colour" },
    .{ .key = "items", .locale = en, .plural = .zero, .text = "no items" },
    .{ .key = "items", .locale = en, .plural = .one, .text = "one item" },
    .{ .key = "items", .locale = en, .plural = .other, .text = "many items" },
};

const sample_catalog: Catalog = .{ .entries = &sample };

test "an exact locale match is preferred" {
    const resolution = sample_catalog.resolve("greeting", fr_ca, 1).?;
    try std.testing.expectEqualStrings("Allo", resolution.text);
    try std.testing.expectEqual(Source.exact, resolution.source);
}

test "a missing region falls back to the same language" {
    // fr-CA has no "colour"; but there is no fr "colour" either, so this checks
    // the greeting: en-GB has no explicit greeting, falls back to en.
    const resolution = sample_catalog.resolve("greeting", en_gb, 1).?;
    try std.testing.expectEqualStrings("Hello", resolution.text);
    try std.testing.expectEqual(Source.language_fallback, resolution.source);
}

test "a region-specific override wins over the base language" {
    // en-GB spells "colour" differently from en.
    const resolution = sample_catalog.resolve("colour", en_gb, 1).?;
    try std.testing.expectEqualStrings("colour", resolution.text);
    try std.testing.expectEqual(Source.exact, resolution.source);
}

test "a language with no translation falls back to the source language" {
    // French has no "colour" at all, so it resolves to the source language.
    const resolution = sample_catalog.resolve("colour", fr, 1).?;
    try std.testing.expectEqualStrings("color", resolution.text);
    try std.testing.expectEqual(Source.source_fallback, resolution.source);
}

test "a regional locale falls back through its language to the source" {
    // fr-CA has no "colour", fr has none either, so it reaches the source.
    const resolution = sample_catalog.resolve("colour", fr_ca, 1).?;
    try std.testing.expectEqualStrings("color", resolution.text);
    try std.testing.expectEqual(Source.source_fallback, resolution.source);
}

test "plural categories select different strings" {
    try std.testing.expectEqualStrings("no items", sample_catalog.resolve("items", en, 0).?.text);
    try std.testing.expectEqualStrings("one item", sample_catalog.resolve("items", en, 1).?.text);
    try std.testing.expectEqualStrings("many items", sample_catalog.resolve("items", en, 2).?.text);
}

test "a plural not translated falls back to the general form" {
    // A locale that only translated `other` still resolves a count of one, to
    // the general form, rather than returning nothing.
    const only_other = [_]Entry{
        .{ .key = "files", .locale = en, .plural = .other, .text = "files" },
    };
    const sparse: Catalog = .{ .entries = &only_other };
    try std.testing.expectEqualStrings("files", sparse.resolve("files", en, 1).?.text);
}

test "a truly missing key returns null so the caller can surface it" {
    // Not a blank and not a crash: the caller gets null and can show the key,
    // which is more useful than empty text.
    try std.testing.expectEqual(@as(?Resolution, null), sample_catalog.resolve("nonexistent", en, 1));
}

test "the fallback order never crosses languages before exhausting one" {
    // A French request for a key only French and English have must return
    // French, never English, when French has it.
    const resolution = sample_catalog.resolve("greeting", fr, 1).?;
    try std.testing.expectEqualStrings("Bonjour", resolution.text);
}

test "the plural rule categorizes counts" {
    try std.testing.expectEqual(Plural.zero, Plural.forCount(0));
    try std.testing.expectEqual(Plural.one, Plural.forCount(1));
    try std.testing.expectEqual(Plural.other, Plural.forCount(2));
    try std.testing.expectEqual(Plural.other, Plural.forCount(1000));
}

test "locale equality distinguishes region" {
    try std.testing.expect(!en.eql(en_gb));
    try std.testing.expect(en.sameLanguage(en_gb));
    try std.testing.expect(!en.sameLanguage(fr));
}
