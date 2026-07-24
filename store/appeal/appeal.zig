//! The appeal state machine for a rejected app, so a developer gets a fair second look exactly
//! once and a decided appeal cannot be reopened forever.
//!
//! Review rejects apps, and sometimes it is wrong — a false positive, a misread policy — so a
//! developer must be able to appeal. But an appeal process has to be bounded, or it becomes a way
//! to relitigate a decision endlessly and tie up review. So the machine is deliberately narrow. A
//! rejected app may be appealed, which sends it to a fresh reviewer; that appeal is decided either
//! upheld — the rejection stands — or overturned, which approves the app. An app may be appealed
//! only from the rejected state and only once per rejection; an appeal already under review cannot
//! be appealed again, and a decided appeal is final for that rejection, so a developer cannot
//! reopen the same decision repeatedly. If the app is changed and resubmitted, that is a new
//! review with its own single appeal, which is the honest path for a genuinely different build.
//! One appeal per rejection, decided once, is what keeps the process fair without making it
//! infinite.
//!
//! This module reviews nothing. It decides whether an appeal action is valid from the current
//! state, as a pure function so the once-and-final guarantee holds in one place.

const std = @import("std");

/// The state of an app's review with respect to appeals.
pub const State = enum {
    /// Rejected by review; an appeal may be filed.
    rejected,
    /// An appeal is under review.
    under_appeal,
    /// The appeal was decided, rejection upheld. Final for this rejection.
    upheld,
    /// The appeal was decided, rejection overturned; the app is approved. Final.
    overturned,

    pub fn isDecided(state: State) bool {
        return state == .upheld or state == .overturned;
    }
};

/// An appeal action.
pub const Action = enum {
    /// File an appeal against a rejection.
    file,
    /// Decide the appeal by upholding the rejection.
    uphold,
    /// Decide the appeal by overturning the rejection.
    overturn,
};

/// The resulting state of a valid action, or that the action is not allowed.
pub const Transition = union(enum) {
    to: State,
    invalid,

    pub fn valid(result: Transition) bool {
        return result == .to;
    }
};

/// Decides the transition for an appeal action from a state.
///
/// An appeal may be filed only from the rejected state, moving it under review — so an app is
/// appealed at most once per rejection and never while already under appeal. An appeal under
/// review may be upheld or overturned, both final. A final state accepts no action, so a decided
/// appeal cannot be reopened; a genuinely changed app takes a new review with its own appeal.
pub fn transition(state: State, action: Action) Transition {
    if (state.isDecided()) return .invalid;
    return switch (state) {
        .rejected => switch (action) {
            .file => .{ .to = .under_appeal },
            else => .invalid,
        },
        .under_appeal => switch (action) {
            .uphold => .{ .to = .upheld },
            .overturn => .{ .to = .overturned },
            .file => .invalid, // cannot appeal an appeal already under review
        },
        .upheld, .overturned => .invalid,
    };
}

test "a rejected app may file one appeal" {
    try std.testing.expectEqual(Transition{ .to = .under_appeal }, transition(.rejected, .file));
}

test "an appeal under review may be upheld or overturned" {
    try std.testing.expectEqual(Transition{ .to = .upheld }, transition(.under_appeal, .uphold));
    try std.testing.expectEqual(Transition{ .to = .overturned }, transition(.under_appeal, .overturn));
}

test "an app under appeal cannot be appealed again" {
    try std.testing.expectEqual(Transition.invalid, transition(.under_appeal, .file));
}

test "a decided appeal is final" {
    for ([_]Action{ .file, .uphold, .overturn }) |action| {
        try std.testing.expectEqual(Transition.invalid, transition(.upheld, action));
        try std.testing.expectEqual(Transition.invalid, transition(.overturned, action));
    }
}

test "an appeal can only be filed from rejected, swept" {
    // The one-appeal property: filing is valid only from the rejected state.
    for (std.enums.values(State)) |state| {
        if (transition(state, .file).valid()) {
            try std.testing.expectEqual(State.rejected, state);
        }
    }
}

test "no final state ever transitions, swept" {
    for ([_]State{ .upheld, .overturned }) |state| {
        for (std.enums.values(Action)) |action| {
            try std.testing.expect(!transition(state, action).valid());
        }
    }
}
