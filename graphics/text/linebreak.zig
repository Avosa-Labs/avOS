//! Breaking a run of words into lines that fit a width, so text wraps at word boundaries
//! and a word too long for the line is placed rather than looping forever.
//!
//! Laying out a paragraph means deciding where each line ends: fit as many words as the
//! width allows, then break and start the next line. The logic is simple until two edge
//! cases, both of which hang a naive implementation. A word wider than the whole line can
//! never fit by the usual rule, so an algorithm that refuses to place a word that does
//! not fit loops forever on it; the line-breaker must place such a word on its own line
//! even though it overflows, because an overflowing word shown is better than a frozen
//! interface. And a zero-width line — a container collapsed to nothing — must not send the
//! breaker into an infinite loop trying to fit a positive-width word into no space; it
//! places one word per line and moves on. Handling both means the breaker always
//! terminates and always makes progress, whatever the words and the width.
//!
//! This module shapes no glyphs. It decides how a sequence of word widths breaks into
//! lines within a maximum line width, as a pure function that always terminates.

const std = @import("std");

/// The width, in the same units as the line width, that a space between words occupies.
pub const space_width: u32 = 1;

/// Breaks a sequence of word widths into lines within `line_width`, writing the count of
/// words on each line into `line_counts` and returning the number of lines.
///
/// Words are added to the current line while they fit; when the next word would overflow,
/// the line is broken and the word starts the next line. A word wider than the whole line
/// is placed alone on its own line and overflows, rather than looping forever trying to
/// fit it — an overflowing word is shown, not hung on. The breaker always advances by at
/// least one word per line, so it terminates for any input, including a zero line width.
pub fn breakLines(word_widths: []const u32, line_width: u32, line_counts: []usize) usize {
    var line: usize = 0;
    var i: usize = 0;
    while (i < word_widths.len) {
        if (line >= line_counts.len) break;
        var used: u64 = 0;
        var on_line: usize = 0;
        // Always place at least one word, so a too-wide word (or a zero width) still
        // advances rather than looping.
        while (i < word_widths.len) {
            const w = word_widths[i];
            const added = if (on_line == 0) w else @as(u64, space_width) + w;
            if (on_line > 0 and used + added > line_width) break;
            used += added;
            on_line += 1;
            i += 1;
        }
        line_counts[line] = on_line;
        line += 1;
    }
    return line;
}

test "words that fit go on one line" {
    const widths = [_]u32{ 3, 3, 3 }; // 3 + 1 + 3 + 1 + 3 = 11
    var lines: [8]usize = undefined;
    const count = breakLines(&widths, 20, &lines);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 3), lines[0]);
}

test "words wrap when they exceed the line width" {
    const widths = [_]u32{ 4, 4, 4 }; // each 4; with spaces, two fit in 9
    var lines: [8]usize = undefined;
    const count = breakLines(&widths, 9, &lines); // 4 + 1 + 4 = 9 fits; third overflows
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 2), lines[0]);
    try std.testing.expectEqual(@as(usize, 1), lines[1]);
}

test "a word wider than the line is placed alone, not looped on" {
    const widths = [_]u32{ 100, 2, 2 }; // first word overflows any small line
    var lines: [8]usize = undefined;
    const count = breakLines(&widths, 5, &lines);
    // First line holds the oversized word alone; the rest wrap after it.
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(@as(usize, 1), lines[0]);
}

test "a zero-width line still terminates, one word per line" {
    const widths = [_]u32{ 2, 2, 2 };
    var lines: [8]usize = undefined;
    const count = breakLines(&widths, 0, &lines);
    try std.testing.expectEqual(@as(usize, 3), count);
    for (lines[0..count]) |on_line| try std.testing.expectEqual(@as(usize, 1), on_line);
}

test "no words is zero lines" {
    var lines: [8]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), breakLines(&.{}, 100, &lines));
}

test "every word is placed on exactly one line, swept" {
    // The progress property: the total words across all lines equals the input count, so
    // no word is lost or duplicated, for a range of widths.
    const widths = [_]u32{ 3, 8, 1, 5, 2, 9, 4 };
    var line_width: u32 = 0;
    while (line_width <= 20) : (line_width += 2) {
        var lines: [16]usize = undefined;
        const count = breakLines(&widths, line_width, &lines);
        var total: usize = 0;
        for (lines[0..count]) |on_line| {
            try std.testing.expect(on_line >= 1); // every line has at least one word
            total += on_line;
        }
        try std.testing.expectEqual(widths.len, total);
    }
}
