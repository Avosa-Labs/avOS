//! Deciding whether a sound plays through silent mode and Do-Not-Disturb, so an alarm the person
//! set to wake up still wakes them while a background app's noise stays silenced.
//!
//! Silent mode and Do-Not-Disturb exist to stop the device making noise the person did not ask for.
//! But an alarm is noise the person did explicitly ask for — they set it, at a time, on purpose,
//! often precisely so they would be woken. Silencing it would defeat the one sound whose whole job is
//! to override quiet. So an alarm or a timer the person themselves set pierces silent mode and DND
//! and sounds anyway; the person's earlier deliberate act outranks the general "be quiet" state. A
//! sound that is not a person-set alarm — a game's effects, an app's notification chime — is
//! suppressed by silent and DND as normal, because nothing about it was requested for this moment.
//! Letting a set alarm through while holding back incidental noise is what makes silent mode safe to
//! use: it quiets the interruptions without quieting the one alert the person is relying on.
//!
//! This module plays no sound. It decides whether a sound is allowed through the quiet modes, from
//! its kind and the quiet state, as a pure function.

const std = @import("std");

/// What kind of sound wants to play.
pub const Sound = enum {
    /// An alarm or timer the person explicitly set. Pierces silent mode and DND.
    person_set_alarm,
    /// Incidental app sound: effects, chimes, notifications. Subject to the quiet modes.
    incidental,
};

/// Whether a sound plays given the device is in a quiet mode (silent or Do-Not-Disturb).
///
/// A person-set alarm plays regardless of the quiet mode — the person asked for it, and that intent
/// outranks the general request for quiet. An incidental sound plays only when no quiet mode is
/// active, so the modes silence the noise the person did not ask for without silencing the alarm they
/// did.
pub fn plays(sound: Sound, quiet_mode_active: bool) bool {
    return switch (sound) {
        .person_set_alarm => true,
        .incidental => !quiet_mode_active,
    };
}

test "a person-set alarm sounds through a quiet mode" {
    try std.testing.expect(plays(.person_set_alarm, true));
}

test "an incidental sound is silenced by a quiet mode" {
    try std.testing.expect(!plays(.incidental, true));
    try std.testing.expect(plays(.incidental, false));
}

test "a quiet mode never silences a person-set alarm, swept" {
    // The alarm-reliability property: a person-set alarm plays in every quiet state.
    for ([_]bool{ false, true }) |quiet| {
        try std.testing.expect(plays(.person_set_alarm, quiet));
    }
}
