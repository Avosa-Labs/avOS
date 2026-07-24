//! The call state machine, so a call moves only through legal states and a call that has
//! ended can never come back to life.
//!
//! A phone call has a lifecycle — it is dialed or it rings, it connects, it is held or
//! resumed, it ends — and which of those transitions are legal is not a detail, it is what
//! keeps the call state honest. The interface, the audio routing, and the network all read
//! the call's state, and if the state could move illegally — from ended back to active, from
//! idle straight to connected — every one of them would act on a call that is not really
//! there, ringing a speaker for a call that hung up or billing for one that never connected.
//! The machine has a clear shape: an outgoing call dials then connects or fails; an incoming
//! call rings then is answered or declined; a connected call may be held and resumed; and any
//! live call may end, which is terminal — a call that has ended stays ended, because a
//! resurrected call is a call the person cannot actually be on. Enforcing the machine is what
//! makes a call something the rest of the system can trust.
//!
//! This module places no call. It decides whether a proposed call-state transition is legal,
//! as a pure function so the terminal-end guarantee holds in one place.

const std = @import("std");

/// The states a call may be in.
pub const State = enum {
    /// No call.
    idle,
    /// Outgoing: dialing, not yet ringing at the other end.
    dialing,
    /// Incoming: ringing, not yet answered.
    ringing,
    /// Connected and active.
    active,
    /// Connected but on hold.
    held,
    /// Ended. Terminal: nothing resumes from here.
    ended,

    pub fn isTerminal(state: State) bool {
        return state == .ended;
    }
};

/// An event that drives a transition.
pub const Event = enum {
    /// Begin an outgoing call.
    dial,
    /// An incoming call arrives.
    incoming,
    /// The call connects (the other end answered, or an incoming call was accepted).
    connect,
    /// Put an active call on hold.
    hold,
    /// Resume a held call.
    resume_call,
    /// End the call. Legal from any live state; always terminal.
    hang_up,
};

/// Whether a transition on `event` from `state` is legal, and the resulting state.
pub const Transition = union(enum) {
    to: State,
    illegal,

    pub fn legal(result: Transition) bool {
        return result == .to;
    }
};

/// Decides the transition for an event from a state.
///
/// From a terminal ended state nothing is legal, so a call that hung up never comes back.
/// Hanging up is legal from any live state and always leads to ended, so a call can always be
/// ended. The rest follow the call's natural shape: dial and incoming start a call from idle,
/// connect moves a dialing or ringing call to active, and hold and resume toggle between
/// active and held. Anything else is illegal.
pub fn transition(state: State, event: Event) Transition {
    if (state.isTerminal()) return .illegal;
    if (event == .hang_up) return .{ .to = .ended };

    return switch (state) {
        .idle => switch (event) {
            .dial => .{ .to = .dialing },
            .incoming => .{ .to = .ringing },
            else => .illegal,
        },
        .dialing, .ringing => switch (event) {
            .connect => .{ .to = .active },
            else => .illegal,
        },
        .active => switch (event) {
            .hold => .{ .to = .held },
            else => .illegal,
        },
        .held => switch (event) {
            .resume_call => .{ .to = .active },
            else => .illegal,
        },
        .ended => .illegal,
    };
}

test "an outgoing call dials then connects" {
    try std.testing.expectEqual(Transition{ .to = .dialing }, transition(.idle, .dial));
    try std.testing.expectEqual(Transition{ .to = .active }, transition(.dialing, .connect));
}

test "an incoming call rings then connects" {
    try std.testing.expectEqual(Transition{ .to = .ringing }, transition(.idle, .incoming));
    try std.testing.expectEqual(Transition{ .to = .active }, transition(.ringing, .connect));
}

test "an active call holds and resumes" {
    try std.testing.expectEqual(Transition{ .to = .held }, transition(.active, .hold));
    try std.testing.expectEqual(Transition{ .to = .active }, transition(.held, .resume_call));
}

test "any live call can hang up" {
    for ([_]State{ .idle, .dialing, .ringing, .active, .held }) |state| {
        try std.testing.expectEqual(Transition{ .to = .ended }, transition(state, .hang_up));
    }
}

test "an ended call accepts no event" {
    for (std.enums.values(Event)) |event| {
        try std.testing.expectEqual(Transition.illegal, transition(.ended, event));
    }
}

test "illegal transitions are rejected" {
    try std.testing.expectEqual(Transition.illegal, transition(.idle, .connect));
    try std.testing.expectEqual(Transition.illegal, transition(.active, .dial));
    try std.testing.expectEqual(Transition.illegal, transition(.held, .hold));
}

test "an ended call never transitions anywhere, swept" {
    // The terminal-end property: from ended, every event is illegal.
    for (std.enums.values(Event)) |event| {
        try std.testing.expect(!transition(.ended, event).legal());
    }
}

test "hang up always ends a live call, swept" {
    for ([_]State{ .idle, .dialing, .ringing, .active, .held }) |state| {
        try std.testing.expectEqual(Transition{ .to = .ended }, transition(state, .hang_up));
    }
}
