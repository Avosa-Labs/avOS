//! Deriving what the task-graph surface shows for each node, so a person watching agents
//! work sees the true state of every branch — including that an action was held for them.
//!
//! The task graph is the heart of the agent-native shell: when a person asks for something,
//! it becomes a visible tree of tasks, and agents work its branches where the person can
//! watch. The surface's job is to show each node's real state, and the states that matter
//! most are the ones a person must act on. A node waiting for the person's approval is not
//! merely "running" — it is stopped, needing them, and the surface must show it as awaiting
//! so it is not lost among the busy branches. A failed or denied node must read as stopped
//! with a reason, not as still working, or a person waits on something that will never
//! finish. And a node's displayed progress reflects its own state and its children's, so a
//! parent shows done only when its subtree is done. Deriving the display honestly from the
//! task state is what makes the graph a window a person can trust rather than a decoration.
//!
//! This module renders no tree. It derives the display state of a node from its task state,
//! as a pure function.

const std = @import("std");

/// The underlying state of a task, from the control plane.
pub const TaskState = enum {
    /// Not yet started.
    pending,
    /// Actively being worked by an agent.
    running,
    /// Stopped, waiting for the person to approve a consequential step.
    awaiting_approval,
    /// Finished successfully.
    succeeded,
    /// Stopped because it was denied or failed.
    stopped,
    /// Cancelled by the person or a parent.
    cancelled,
};

/// How a node reads on the surface.
pub const Display = enum {
    /// Queued, not started.
    queued,
    /// Working now.
    active,
    /// Needs the person: an action is held for approval. Surfaced prominently.
    needs_you,
    /// Done.
    done,
    /// Stopped with a reason (denied, failed, cancelled). Not still working.
    ended,

    /// Whether this display reads as still in progress, so the person knows work continues.
    pub fn inProgress(d: Display) bool {
        return d == .queued or d == .active or d == .needs_you;
    }
};

/// Derives the display state of a node from its task state.
///
/// A task awaiting approval is shown as needs-you, never as active, so a held action is not
/// lost among the working branches. A succeeded task is done; a stopped or cancelled task is
/// ended with a reason, never shown as still working, so a person never waits on something
/// finished. Pending is queued and running is active.
pub fn display(state: TaskState) Display {
    return switch (state) {
        .pending => .queued,
        .running => .active,
        .awaiting_approval => .needs_you,
        .succeeded => .done,
        .stopped, .cancelled => .ended,
    };
}

test "a running task shows active" {
    try std.testing.expectEqual(Display.active, display(.running));
}

test "an awaiting-approval task shows needs-you, not active" {
    const d = display(.awaiting_approval);
    try std.testing.expectEqual(Display.needs_you, d);
    try std.testing.expect(d != .active);
}

test "a succeeded task shows done" {
    try std.testing.expectEqual(Display.done, display(.succeeded));
}

test "stopped and cancelled tasks show ended, not in progress" {
    try std.testing.expectEqual(Display.ended, display(.stopped));
    try std.testing.expectEqual(Display.ended, display(.cancelled));
    try std.testing.expect(!display(.stopped).inProgress());
    try std.testing.expect(!display(.cancelled).inProgress());
}

test "a held action always reads as needing the person, swept" {
    // The don't-lose-a-held-action property: awaiting_approval always maps to needs_you and
    // needs_you reads as in progress so the person knows to act.
    try std.testing.expectEqual(Display.needs_you, display(.awaiting_approval));
    try std.testing.expect(display(.awaiting_approval).inProgress());
}

test "no finished task ever reads as in progress, swept" {
    // The don't-wait-on-finished property: succeeded, stopped, and cancelled never read as
    // in progress.
    for ([_]TaskState{ .succeeded, .stopped, .cancelled }) |state| {
        try std.testing.expect(!display(state).inProgress());
    }
}
