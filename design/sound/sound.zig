//! Deciding whether a system sound plays, honouring silent mode and focus while letting
//! the few sounds that protect a person through, so the device is quiet when asked but
//! never mutes an alarm.
//!
//! A phone makes sounds, and most of them a person can and should be able to silence: the
//! keyboard click, the sent-message swoosh, the notification chime. When the ringer is off
//! or a focus mode is on, those go quiet, because a device that beeps through a meeting or
//! a night's sleep is a device people learn to hate. But a small set of sounds is not the
//! device's to silence. An alarm the person set, an emergency alert, the shutter sound
//! some jurisdictions require — these play regardless, because silencing them could cause a
//! missed wake-up, a missed warning, or a legal problem. So a system sound carries a
//! category, and whether it plays depends on that category against the device's sound
//! state: ordinary sounds obey silent mode and focus, and the protected few override them.
//! The device is quiet by default and loud only when it must be.
//!
//! This module plays no sound. It decides whether a sound of a category plays given the
//! device's sound state, as a pure function.

const std = @import("std");

/// What a sound is for, which sets whether the person may silence it.
pub const Category = enum {
    /// UI feedback: key clicks, sent sounds. Silenced freely.
    ui_feedback,
    /// A notification or ringtone. Silenced by silent mode and focus.
    notification,
    /// A protected sound that plays regardless: an alarm, an emergency alert, a
    /// mandatory shutter sound.
    protected,

    fn overridesSilence(category: Category) bool {
        return category == .protected;
    }
};

/// The device's current sound state.
pub const SoundState = struct {
    /// Whether the ringer/silent switch is set to silent.
    silent: bool,
    /// Whether a focus mode that suppresses notification sounds is active.
    focus_suppressing: bool,
};

/// Whether a sound of a category plays, given the device's sound state.
///
/// A protected sound always plays — the device does not silence an alarm or an emergency
/// alert. Any other sound is silenced when the device is in silent mode or a suppressing
/// focus is active, so the ordinary chimes and clicks obey the person's request for quiet.
/// The default for a non-protected sound under either quiet condition is not to play.
pub fn plays(category: Category, state: SoundState) bool {
    if (category.overridesSilence()) return true;
    if (state.silent or state.focus_suppressing) return false;
    return true;
}

test "an alarm plays through silent mode and focus" {
    try std.testing.expect(plays(.protected, .{ .silent = true, .focus_suppressing = true }));
}

test "a notification is silenced by silent mode" {
    try std.testing.expect(!plays(.notification, .{ .silent = true, .focus_suppressing = false }));
}

test "a notification is silenced by a suppressing focus" {
    try std.testing.expect(!plays(.notification, .{ .silent = false, .focus_suppressing = true }));
}

test "sounds play normally when the device is not quiet" {
    const loud: SoundState = .{ .silent = false, .focus_suppressing = false };
    try std.testing.expect(plays(.ui_feedback, loud));
    try std.testing.expect(plays(.notification, loud));
}

test "a protected sound plays in every state, swept" {
    // The safety property: an alarm or emergency sound is never silenced.
    for ([_]bool{ false, true }) |silent| {
        for ([_]bool{ false, true }) |focus| {
            try std.testing.expect(plays(.protected, .{ .silent = silent, .focus_suppressing = focus }));
        }
    }
}

test "a non-protected sound never plays while the device is quiet, swept" {
    // The quiet property: under silent mode or a suppressing focus, ordinary sounds stay
    // silent.
    for ([_]Category{ .ui_feedback, .notification }) |category| {
        try std.testing.expect(!plays(category, .{ .silent = true, .focus_suppressing = false }));
        try std.testing.expect(!plays(category, .{ .silent = false, .focus_suppressing = true }));
    }
}
