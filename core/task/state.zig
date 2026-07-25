//! The task state machine: the states a task may be in and the moves between them.
//!
//! Written as one total transition table so the machine can be read and tested in
//! one place. Every move is either explicitly allowed or explicitly refused,
//! terminal states stay terminal, and repeating a move that already happened is
//! redundant rather than an error, so a retried message after a restart cannot
//! corrupt the graph.

pub const State = enum {
    planned,
    waiting_for_dependency,
    waiting_for_capability,
    waiting_for_approval,
    runnable,
    running,
    cancelling,
    cancelled,
    succeeded,
    failed,

    /// A terminal state is never left. Work that reached one is finished, and
    /// its resources have been released.
    pub fn isTerminal(state: State) bool {
        return switch (state) {
            .cancelled, .succeeded, .failed => true,
            .planned,
            .waiting_for_dependency,
            .waiting_for_capability,
            .waiting_for_approval,
            .runnable,
            .running,
            .cancelling,
            => false,
        };
    }

    /// Whether the task is blocked awaiting something external to it.
    pub fn isBlocked(state: State) bool {
        return switch (state) {
            .waiting_for_dependency, .waiting_for_capability, .waiting_for_approval => true,
            else => false,
        };
    }

    /// Whether cancelling this task requires passing through `cancelling`.
    ///
    /// Work that has begun must be given the chance to stop at a cancellation
    /// point and release what it holds. Work that never started can be
    /// abandoned directly.
    pub fn requiresWindDown(state: State) bool {
        return state == .running;
    }
};

/// Whether a transition is permitted, and why not when it is refused.
pub const Transition = enum {
    allowed,
    /// The task is already in the requested state.
    redundant,
    /// The task has finished; nothing may move it.
    terminal,
    /// The transition is not part of the machine.
    forbidden,
};

/// The complete transition table.
///
/// Written as one function rather than scattered checks so that the machine can
/// be read, and tested, in a single place. Anything not named here is refused.
pub fn classify(from: State, to: State) Transition {
    if (from == to) return .redundant;
    if (from.isTerminal()) return .terminal;

    const allowed = switch (from) {
        .planned => switch (to) {
            .waiting_for_dependency,
            .waiting_for_capability,
            .waiting_for_approval,
            .runnable,
            .cancelled,
            .failed,
            => true,
            else => false,
        },
        .waiting_for_dependency => switch (to) {
            .waiting_for_capability,
            .waiting_for_approval,
            .runnable,
            .cancelled,
            .failed,
            => true,
            else => false,
        },
        .waiting_for_capability => switch (to) {
            .waiting_for_approval, .runnable, .cancelled, .failed => true,
            else => false,
        },
        // A denied approval fails the task; it does not silently proceed.
        .waiting_for_approval => switch (to) {
            .runnable, .cancelled, .failed => true,
            else => false,
        },
        .runnable => switch (to) {
            .running, .waiting_for_dependency, .waiting_for_capability, .cancelled, .failed => true,
            else => false,
        },
        // Running work may block again, wind down, or finish.
        .running => switch (to) {
            .waiting_for_dependency,
            .waiting_for_capability,
            .waiting_for_approval,
            .cancelling,
            .succeeded,
            .failed,
            => true,
            else => false,
        },
        // Winding down may complete an operation that had already committed,
        // which is why `succeeded` is reachable from here.
        .cancelling => switch (to) {
            .cancelled, .succeeded, .failed => true,
            else => false,
        },
        .cancelled, .succeeded, .failed => false,
    };

    return if (allowed) .allowed else .forbidden;
}
