//! The accessibility settings, and the promise that turning one on cannot make
//! the device unusable.
//!
//! Accessibility settings are not decoration a person opts into; for many people
//! they are the difference between a device that works and one that does not. So
//! they carry a stronger guarantee than an ordinary preference: a setting must
//! take effect everywhere, and no combination of settings may produce a state a
//! person cannot operate. The classic failure is a text scale so large that a
//! confirm button is pushed off screen, or a reduced-motion setting a surface
//! honours in one place and ignores in another. Both turn an accessibility aid
//! into a trap.
//!
//! This module holds the settings and the rules that keep them coherent: a text
//! scale is clamped to a range that stays legible without breaking layout, a
//! setting is either fully in effect or not (never partially), and the
//! combination is validated so that enabling one never silently disables the
//! guarantee of another. It renders nothing; it is the state every surface reads
//! and must honour.

const std = @import("std");

/// How much larger than default to draw text, in hundredths.
///
/// 100 is the default size. Clamped to a range: below it text is too small to be
/// the accessibility aid it exists to be, and above it layout breaks in ways
/// that hide controls, which is its own accessibility failure.
pub const TextScale = struct {
    hundredths: u16,

    pub const default: TextScale = .{ .hundredths = 100 };
    pub const min_hundredths: u16 = 80;
    pub const max_hundredths: u16 = 300;

    /// Clamps a requested scale into the usable range.
    ///
    /// A person can ask for anything; what they get is bounded so that neither
    /// extreme produces a screen they cannot use. Clamping rather than rejecting
    /// means a slider dragged to the end lands at the largest safe size instead
    /// of refusing.
    pub fn clamp(requested: u16) TextScale {
        return .{ .hundredths = std.math.clamp(requested, min_hundredths, max_hundredths) };
    }

    /// Whether the largest text still leaves room for controls.
    ///
    /// The property a layout must hold at the maximum scale, checked here so a
    /// surface can assert against it rather than discovering a clipped button.
    pub fn isLayoutSafe(scale: TextScale) bool {
        return scale.hundredths >= min_hundredths and scale.hundredths <= max_hundredths;
    }
};

/// The full set of accessibility settings.
///
/// Flat and explicit: every setting a surface must honour is here, so a surface
/// reads one value and cannot miss a setting that lived somewhere else.
pub const Settings = struct {
    text_scale: TextScale = .default,
    /// Suppress non-essential motion. Animation that conveys no information is
    /// stilled; motion that carries meaning is replaced with a non-moving cue,
    /// never simply dropped.
    reduce_motion: bool = false,
    /// Raise contrast to the level a low-vision person needs. Distinct from a
    /// dark theme, which is a preference, not an aid.
    high_contrast: bool = false,
    /// A screen reader is active. Surfaces must expose a described structure and
    /// must not rely on anything only a sighted person perceives.
    screen_reader: bool = false,
    /// Extend every timed interaction. A prompt that vanishes on a timer is
    /// unusable for someone who needs longer to respond, so timers lengthen or
    /// wait.
    extend_timeouts: bool = false,
    /// Reduce transparency and blur, which lower effective contrast and can
    /// induce discomfort.
    reduce_transparency: bool = false,

    /// Whether these settings are internally coherent.
    ///
    /// The invariant the whole module protects: no combination produces an
    /// unusable device. A screen reader implies motion carries no essential
    /// information a blind person would miss, and a large text scale must stay
    /// layout-safe. A combination that violated either would be an aid that
    /// disables the device, which is worse than no aid.
    pub fn isCoherent(settings: Settings) bool {
        if (!settings.text_scale.isLayoutSafe()) return false;
        // A screen reader with motion still enabled is fine — motion is simply
        // not perceived — but it must go with extended timeouts, because a
        // person navigating by audio needs longer than a timed prompt allows.
        if (settings.screen_reader and !settings.extend_timeouts) return false;
        return true;
    }

    /// Returns a coherent version of these settings, adjusting the minimum
    /// number of fields.
    ///
    /// Applied when settings are loaded or changed, so an incoherent combination
    /// — from an old profile, a sync, a bug — becomes usable rather than being
    /// rejected and leaving the person with nothing. The adjustments are the
    /// ones that preserve the person's evident intent: a screen reader stays on
    /// and gains the extended timeouts it needs.
    pub fn madeCoherent(settings: Settings) Settings {
        var coherent = settings;
        coherent.text_scale = TextScale.clamp(settings.text_scale.hundredths);
        if (coherent.screen_reader) coherent.extend_timeouts = true;
        return coherent;
    }

    /// Whether any accessibility aid is active.
    ///
    /// A surface can take a faster path when nothing is on, but must never assume
    /// it: the default is all-off, and a person turns these on precisely when the
    /// default did not serve them.
    pub fn anyEnabled(settings: Settings) bool {
        return settings.text_scale.hundredths != TextScale.default.hundredths or
            settings.reduce_motion or
            settings.high_contrast or
            settings.screen_reader or
            settings.extend_timeouts or
            settings.reduce_transparency;
    }
};

test "the default settings are coherent and inert" {
    const settings: Settings = .{};
    try std.testing.expect(settings.isCoherent());
    try std.testing.expect(!settings.anyEnabled());
}

test "a text scale is clamped to the usable range" {
    // Too small to help, and too large to lay out, both land at the bounds
    // rather than being refused.
    try std.testing.expectEqual(TextScale.min_hundredths, TextScale.clamp(10).hundredths);
    try std.testing.expectEqual(TextScale.max_hundredths, TextScale.clamp(1000).hundredths);
    try std.testing.expectEqual(@as(u16, 150), TextScale.clamp(150).hundredths);
}

test "the largest permitted text is still layout-safe" {
    // The property a layout holds even at maximum: a surface can rely on it.
    try std.testing.expect((TextScale{ .hundredths = TextScale.max_hundredths }).isLayoutSafe());
    try std.testing.expect(!(TextScale{ .hundredths = TextScale.max_hundredths + 1 }).isLayoutSafe());
}

test "a screen reader requires extended timeouts to be coherent" {
    // A person navigating by audio needs longer than a timed prompt allows, so
    // this combination is incoherent.
    const incoherent: Settings = .{ .screen_reader = true, .extend_timeouts = false };
    try std.testing.expect(!incoherent.isCoherent());

    const coherent: Settings = .{ .screen_reader = true, .extend_timeouts = true };
    try std.testing.expect(coherent.isCoherent());
}

test "making settings coherent preserves the person's intent" {
    // A screen reader without extended timeouts: the fix keeps the reader on and
    // grants the timeouts, rather than turning the reader off.
    const requested: Settings = .{ .screen_reader = true, .extend_timeouts = false };
    const adjusted = requested.madeCoherent();
    try std.testing.expect(adjusted.screen_reader);
    try std.testing.expect(adjusted.extend_timeouts);
    try std.testing.expect(adjusted.isCoherent());
}

test "making settings coherent clamps an out-of-range text scale" {
    const requested: Settings = .{ .text_scale = .{ .hundredths = 5000 } };
    const adjusted = requested.madeCoherent();
    try std.testing.expectEqual(TextScale.max_hundredths, adjusted.text_scale.hundredths);
    try std.testing.expect(adjusted.isCoherent());
}

test "made-coherent settings are always coherent, across combinations" {
    // The invariant the module exists for: whatever incoherent state arrives,
    // the result is usable. Swept across every boolean combination.
    for (0..64) |bits| {
        const settings: Settings = .{
            .text_scale = if (bits & 1 != 0) .{ .hundredths = 9999 } else .default,
            .reduce_motion = bits & 2 != 0,
            .high_contrast = bits & 4 != 0,
            .screen_reader = bits & 8 != 0,
            .extend_timeouts = bits & 16 != 0,
            .reduce_transparency = bits & 32 != 0,
        };
        try std.testing.expect(settings.madeCoherent().isCoherent());
    }
}

test "any single aid registers as enabled" {
    // A surface that special-cases all-off must still see each aid individually.
    try std.testing.expect((Settings{ .reduce_motion = true }).anyEnabled());
    try std.testing.expect((Settings{ .high_contrast = true }).anyEnabled());
    try std.testing.expect((Settings{ .text_scale = .{ .hundredths = 120 } }).anyEnabled());
    try std.testing.expect((Settings{ .reduce_transparency = true }).anyEnabled());
}

test "a coherent screen-reader profile counts as enabled" {
    const settings = (Settings{ .screen_reader = true }).madeCoherent();
    try std.testing.expect(settings.anyEnabled());
}

test "clamping is idempotent" {
    // Clamping an already-clamped value does not move it, so applying settings
    // twice is stable.
    const once = TextScale.clamp(500);
    const twice = TextScale.clamp(once.hundredths);
    try std.testing.expectEqual(once.hundredths, twice.hundredths);
}
