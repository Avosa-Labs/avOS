//! Deciding whether a keystroke commits an in-progress composition or extends it, so
//! languages that build a character from several keys commit exactly when the person means
//! to.
//!
//! Many writing systems are typed by composition: a run of keystrokes builds up a syllable
//! or a character, and at some point that composed text is committed into the document.
//! Getting the commit moment right is what makes input-method typing feel natural. While a
//! composition is in progress, a key that adds to it extends the composition, shown as
//! provisional, underlined text the person can still change. A commit key — a space, a
//! return, or the selection of a candidate — finalizes the composition into real text.
//! And a key that belongs to neither — an arrow, an escape — cancels the composition rather
//! than being folded into it, because the person has moved on. Deciding commit, extend, or
//! cancel for each key is the whole contract of a composition engine: commit too eagerly
//! and half-formed characters land in the text; commit too late and finished text stays
//! stuck as provisional.
//!
//! This module composes no text. It decides what a keystroke does to a composition —
//! extend, commit, or cancel — as a pure function over the key and the composition state.

const std = @import("std");

/// The kind of key pressed, as it bears on composition.
pub const Key = enum {
    /// A character key that adds to a composition.
    composing,
    /// A commit key: space, return, or a chosen candidate. Finalizes the composition.
    commit,
    /// A navigation or control key: arrows, escape. Ends the composition without folding
    /// the key in.
    control,
};

/// What a keystroke does to a composition.
pub const Action = enum {
    /// Extend the in-progress composition with this key.
    extend,
    /// Commit the composition into real text.
    commit,
    /// Cancel the composition, discarding the provisional text.
    cancel,
    /// No composition is active; the key is handled normally.
    passthrough,

    pub fn commits(action: Action) bool {
        return action == .commit;
    }
};

/// Decides what a keystroke does, given whether a composition is currently in progress.
///
/// With no composition active, a composing key starts one (extend) and any other key
/// passes through to normal handling. With a composition active, a composing key extends
/// it, a commit key finalizes it, and a control key cancels it — the person navigating away
/// ends the composition rather than corrupting it. This keeps provisional text provisional
/// until the person signals they are done with it.
pub fn resolve(key: Key, composing_active: bool) Action {
    if (!composing_active) {
        return switch (key) {
            .composing => .extend, // starts a new composition
            .commit, .control => .passthrough,
        };
    }
    return switch (key) {
        .composing => .extend,
        .commit => .commit,
        .control => .cancel,
    };
}

test "a composing key starts a composition when none is active" {
    try std.testing.expectEqual(Action.extend, resolve(.composing, false));
}

test "a non-composing key passes through when none is active" {
    try std.testing.expectEqual(Action.passthrough, resolve(.commit, false));
    try std.testing.expectEqual(Action.passthrough, resolve(.control, false));
}

test "a composing key extends an active composition" {
    try std.testing.expectEqual(Action.extend, resolve(.composing, true));
}

test "a commit key finalizes an active composition" {
    try std.testing.expectEqual(Action.commit, resolve(.commit, true));
}

test "a control key cancels an active composition" {
    try std.testing.expectEqual(Action.cancel, resolve(.control, true));
}

test "a commit only ever happens on a commit key during an active composition, swept" {
    // The precise-commit property: nothing commits except a commit key while composing.
    for ([_]Key{ .composing, .commit, .control }) |key| {
        for ([_]bool{ false, true }) |active| {
            if (resolve(key, active).commits()) {
                try std.testing.expect(key == .commit and active);
            }
        }
    }
}
