//! Deciding how a screenless endpoint confirms a consequential action, so a voice-only surface never
//! commits something irreversible without a spoken confirmation the person can still take back.
//!
//! A screenless endpoint — a speaker, an earpiece, a voice-only surface — has no display to show a
//! confirmation dialog and no button to cancel one. Everything happens in sound, and sound is
//! fleeting: a person may mishear, an agent may mistranscribe, an overheard phrase may be taken as a
//! command. For an ordinary action, acting and narrating the result is fine. For a consequential
//! action — one with an external, irreversible effect — that is not enough, because a mistaken voice
//! command with no undo is exactly the failure a screenless surface is prone to. So the platform
//! requires a reversible audio confirmation: before a consequential action commits, the endpoint states
//! what it is about to do and gives the person a spoken, in-the-moment way to stop it, and only after
//! that window passes does the action run. The confirmation must be reversible — a real chance to say
//! "no", not an announcement after the fact. Requiring reversible audio confirmation for consequential
//! actions is what makes a voice-only endpoint safe to act through rather than a place where a
//! misheard word does something that cannot be undone.
//!
//! This module speaks nothing. It decides whether an action may commit on a screenless endpoint, from
//! whether it is consequential and whether a reversible audio confirmation was given, as a pure
//! function.

const std = @import("std");

/// What is being attempted on the screenless endpoint.
pub const Action = enum {
    /// An ordinary action with no irreversible external effect.
    ordinary,
    /// A consequential action — an external, irreversible effect.
    consequential,
};

/// Whether an action may commit on a screenless endpoint.
///
/// An ordinary action commits directly. A consequential action commits only after a reversible audio
/// confirmation was given — the spoken statement of intent and the chance to stop it — so no
/// irreversible effect follows a single unconfirmed voice command.
pub fn mayCommit(action: Action, reversible_audio_confirmed: bool) bool {
    return switch (action) {
        .ordinary => true,
        .consequential => reversible_audio_confirmed,
    };
}

test "an ordinary action commits directly" {
    try std.testing.expect(mayCommit(.ordinary, false));
}

test "a consequential action needs reversible audio confirmation" {
    try std.testing.expect(!mayCommit(.consequential, false));
    try std.testing.expect(mayCommit(.consequential, true));
}

test "no consequential action commits without confirmation, swept" {
    // The reversible-confirmation property: a committed consequential action was confirmed.
    for ([_]bool{ false, true }) |confirmed| {
        if (mayCommit(.consequential, confirmed)) {
            try std.testing.expect(confirmed);
        }
    }
}
