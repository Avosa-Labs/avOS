//! The agent lifecycle state machine, so an agent moves only through states that
//! make sense and a terminated agent can never come back to act.
//!
//! An agent has a life: it is created, it runs, it may be paused and resumed, and it
//! ends. Which of those moves are allowed is a safety question, not a bookkeeping one.
//! An agent that has been terminated must stay terminated — resurrecting a stopped
//! agent would revive whatever authority it held after a person or the system decided
//! it should stop, which is precisely what stopping was meant to prevent. A suspended
//! agent holds its state but runs nothing, so it cannot act while paused. And an agent
//! cannot run before it has been admitted or after it has ended. The transitions form
//! a small graph with one-way doors: some states can be returned from, and termination
//! cannot. Enforcing the graph is what makes an agent's stop actually stop it.
//!
//! This module runs no agent. It decides whether a proposed lifecycle transition is
//! valid from the current state, as a pure function so the one-way doors hold in one
//! place.

const std = @import("std");

/// The states an agent may be in.
pub const State = enum {
    /// Admitted but not yet running.
    created,
    /// Actively running.
    running,
    /// Paused: state retained, executing nothing.
    suspended,
    /// Ended. A terminal state: nothing resumes from here.
    terminated,

    /// Whether this is a terminal state from which no transition is allowed.
    pub fn isTerminal(state: State) bool {
        return state == .terminated;
    }
};

/// A lifecycle event that requests a transition.
pub const Event = enum {
    /// Begin running (from created or suspended).
    start,
    /// Pause a running agent.
    suspend_agent,
    /// Resume a suspended agent.
    resume_agent,
    /// End the agent. Allowed from any non-terminal state; always one-way.
    terminate,
};

/// The next state for a valid transition, or that the transition is not allowed.
pub const Transition = union(enum) {
    to: State,
    invalid,

    pub fn valid(result: Transition) bool {
        return result == .to;
    }
};

/// Decides the transition for an event from a state.
///
/// Termination is allowed from any live state and always leads to the terminal state,
/// so an agent can always be stopped. No event is allowed from the terminal state, so
/// a terminated agent never runs again. The remaining moves follow the natural graph:
/// start runs a created or suspended agent, suspend pauses a running one, and resume
/// runs a suspended one. Anything else — starting a running agent, suspending a
/// created one — is invalid.
pub fn transition(state: State, event: Event) Transition {
    // A terminated agent accepts nothing: the one-way door.
    if (state.isTerminal()) return .invalid;

    // Terminate is always available from a live state.
    if (event == .terminate) return .{ .to = .terminated };

    return switch (state) {
        .created => switch (event) {
            .start => .{ .to = .running },
            else => .invalid,
        },
        .running => switch (event) {
            .suspend_agent => .{ .to = .suspended },
            else => .invalid,
        },
        .suspended => switch (event) {
            .start, .resume_agent => .{ .to = .running },
            else => .invalid,
        },
        .terminated => .invalid, // unreachable given the guard above
    };
}

test "a created agent starts into running" {
    try std.testing.expectEqual(Transition{ .to = .running }, transition(.created, .start));
}

test "a running agent suspends and resumes" {
    try std.testing.expectEqual(Transition{ .to = .suspended }, transition(.running, .suspend_agent));
    try std.testing.expectEqual(Transition{ .to = .running }, transition(.suspended, .resume_agent));
}

test "any live agent can be terminated" {
    try std.testing.expectEqual(Transition{ .to = .terminated }, transition(.created, .terminate));
    try std.testing.expectEqual(Transition{ .to = .terminated }, transition(.running, .terminate));
    try std.testing.expectEqual(Transition{ .to = .terminated }, transition(.suspended, .terminate));
}

test "a terminated agent accepts no event" {
    for (std.enums.values(Event)) |event| {
        try std.testing.expectEqual(Transition.invalid, transition(.terminated, event));
    }
}

test "invalid moves are rejected" {
    // Starting an already-running agent, suspending a created one.
    try std.testing.expectEqual(Transition.invalid, transition(.running, .start));
    try std.testing.expectEqual(Transition.invalid, transition(.created, .suspend_agent));
    try std.testing.expectEqual(Transition.invalid, transition(.created, .resume_agent));
}

test "no transition ever leaves the terminal state, swept" {
    // The one-way-door property: from terminated, every event is invalid, so nothing
    // ever resumes.
    for (std.enums.values(Event)) |event| {
        try std.testing.expect(!transition(.terminated, event).valid());
    }
}

test "terminate always succeeds from a live state and always ends, swept" {
    for ([_]State{ .created, .running, .suspended }) |state| {
        const result = transition(state, .terminate);
        try std.testing.expectEqual(Transition{ .to = .terminated }, result);
    }
}
