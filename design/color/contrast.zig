//! Deciding whether a foreground and background colour have enough contrast to be read,
//! so text is never rendered in a pairing a person with low vision cannot make out.
//!
//! Text is only usable if it stands out from what is behind it, and "stands out" is not a
//! matter of taste — it is a measurable ratio between the luminance of the foreground and
//! the background, and there are thresholds below which a large fraction of people simply
//! cannot read the text. Small body text needs a higher ratio than large headings,
//! because size compensates for contrast. A design system that leaves this to the eye of
//! whoever picked the colours ships text that looks fine to them and is invisible to
//! someone with low vision or on a dim screen in sunlight. So a colour pairing carries a
//! computed contrast ratio, and a pairing is accepted for a given text size only if it
//! meets the threshold for that size — checked as a number, not judged in a review. The
//! result is that every text-on-background combination the system produces is one that
//! meets a stated legibility bar.
//!
//! This module renders no text. It computes the contrast ratio between two luminances and
//! decides whether a pairing passes for a text size, as pure functions.

const std = @import("std");

/// The relative luminance of a colour, 0 (black) to 1 (white). Callers compute this from
/// the colour's channels; the contrast rule is the same whatever the colour space.
pub const Luminance = f32;

/// The contrast ratio between two luminances, per the standard definition: the lighter
/// plus a small offset over the darker plus the same offset. Ranges from 1 (identical) to
/// 21 (black on white).
pub fn ratio(a: Luminance, b: Luminance) f32 {
    const lighter = @max(a, b);
    const darker = @min(a, b);
    return (lighter + 0.05) / (darker + 0.05);
}

/// The size class of text, which sets the contrast threshold it must meet.
pub const TextSize = enum {
    /// Ordinary body text. Needs the higher threshold.
    body,
    /// Large text — headings, or bold text above a size. A lower threshold suffices
    /// because the larger strokes are easier to resolve.
    large,

    /// The minimum contrast ratio this size must meet to be legible (WCAG AA).
    fn threshold(size: TextSize) f32 {
        return switch (size) {
            .body => 4.5,
            .large => 3.0,
        };
    }
};

/// Whether a foreground/background pairing meets the contrast threshold for a text size.
///
/// The computed ratio must be at least the threshold for the size — 4.5 for body, 3.0 for
/// large. A pairing that meets it is legible for that size; one that does not is rejected,
/// so no under-contrast text reaches the screen. Large text passing does not imply the
/// same pairing passes for body, which is exactly why the size is part of the decision.
pub fn passes(foreground: Luminance, background: Luminance, size: TextSize) bool {
    return ratio(foreground, background) >= size.threshold();
}

test "black on white has maximal contrast and passes everything" {
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), ratio(0.0, 1.0), 0.01);
    try std.testing.expect(passes(0.0, 1.0, .body));
    try std.testing.expect(passes(0.0, 1.0, .large));
}

test "identical colours have ratio one and pass nothing" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ratio(0.5, 0.5), 0.001);
    try std.testing.expect(!passes(0.5, 0.5, .body));
    try std.testing.expect(!passes(0.5, 0.5, .large));
}

test "the ratio is symmetric in its arguments" {
    try std.testing.expectEqual(ratio(0.2, 0.8), ratio(0.8, 0.2));
}

test "a pairing may pass for large text but not body" {
    // Find a luminance pair whose ratio is between 3.0 and 4.5.
    const fg: Luminance = 0.0;
    const bg: Luminance = 0.18; // ratio = (0.18+0.05)/(0+0.05) = 4.6... adjust
    _ = bg;
    const mid: Luminance = 0.15; // (0.15+0.05)/0.05 = 4.0
    try std.testing.expect(ratio(fg, mid) >= 3.0 and ratio(fg, mid) < 4.5);
    try std.testing.expect(passes(fg, mid, .large));
    try std.testing.expect(!passes(fg, mid, .body));
}

test "body text needs a higher threshold than large text" {
    try std.testing.expect(TextSize.body.threshold() > TextSize.large.threshold());
}

test "any passing pairing meets its size threshold, swept" {
    // The legibility property: whenever passes is true, the ratio is at least the
    // threshold for that size.
    const luminances = [_]Luminance{ 0.0, 0.1, 0.25, 0.5, 0.75, 1.0 };
    for (luminances) |fg| {
        for (luminances) |bg| {
            for ([_]TextSize{ .body, .large }) |size| {
                if (passes(fg, bg, size)) {
                    try std.testing.expect(ratio(fg, bg) >= size.threshold());
                }
            }
        }
    }
}
