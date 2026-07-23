//! Keeping an agent's control of a physical device inside a safety envelope,
//! and handing control back to a person on demand.
//!
//! When an agent controls something in the world — a motor, a lock, a valve, a
//! vehicle subsystem — a mistake is not a wrong answer on a screen; it is a
//! physical event. So agent device control is not the same as agent computation.
//! It runs inside a safety envelope the agent cannot widen: a command outside the
//! envelope is refused rather than clamped-and-run, because clamping a dangerous
//! command to a safe one still executes something the operator did not intend.
//! And a person can take over at any moment, immediately, without the agent's
//! cooperation, because the one guarantee that makes autonomous physical control
//! acceptable is that a human can always stop it.
//!
//! This module holds the envelope check and the takeover state. It moves no
//! actuator; it decides whether a proposed command is within bounds and whether
//! the agent is even permitted to command right now, so the safety property is
//! enforced at one gate rather than trusted to every controller.

const std = @import("std");

/// A physical quantity an agent might command, in fixed units so a bound means
/// the same thing everywhere.
pub const Command = struct {
    /// What is being commanded.
    axis: Axis,
    /// The commanded value, in the axis's units (milli-units to stay integer).
    value: i32,

    pub const Axis = enum {
        /// Movement speed, in millimetres per second. Signed for direction.
        velocity,
        /// Applied force or torque, in milli-newtons or milli-newton-metres.
        force,
        /// A position or angle setpoint, in milli-units.
        position,
        /// A discrete state: a lock engaged or not, a valve open or shut. The
        /// value is 0 or 1.
        discrete,
    };
};

/// The bounds one axis is allowed to operate within.
pub const Bound = struct {
    min: i32,
    max: i32,

    fn contains(bound: Bound, value: i32) bool {
        return value >= bound.min and value <= bound.max;
    }
};

/// The safety envelope: the bounds for each axis. A command outside its axis's
/// bound is unsafe by definition.
pub const Envelope = struct {
    velocity: Bound,
    force: Bound,
    position: Bound,
    discrete: Bound = .{ .min = 0, .max = 1 },

    fn boundFor(envelope: Envelope, axis: Command.Axis) Bound {
        return switch (axis) {
            .velocity => envelope.velocity,
            .force => envelope.force,
            .position => envelope.position,
            .discrete => envelope.discrete,
        };
    }
};

/// Why a command was refused.
pub const Refusal = enum {
    /// A person has taken control; the agent may not command until they release
    /// it. The takeover guarantee: a human always wins.
    operator_in_control,
    /// The command is outside the safety envelope. Refused, not clamped, because
    /// a clamped command still runs something unintended.
    outside_envelope,
    /// The controller is in a safe-stop state and accepts no commands until
    /// reset.
    safe_stopped,
};

/// The outcome of a command attempt.
pub const Decision = union(enum) {
    execute,
    refuse: Refusal,

    pub fn executes(decision: Decision) bool {
        return decision == .execute;
    }
};

/// Who is currently in control of the device.
pub const Controller = enum {
    /// The agent commands, within the envelope.
    agent,
    /// A person has taken over. The agent is locked out until they release.
    operator,
    /// A safety condition tripped a stop. No one commands until it is reset.
    safe_stop,
};

/// The device-control state an agent operates against.
pub const Control = struct {
    envelope: Envelope,
    controller: Controller = .agent,

    /// A person takes control, immediately and without the agent's cooperation.
    ///
    /// This is the takeover guarantee. It always succeeds and takes effect at
    /// once: there is no state from which a person cannot seize control, because
    /// an agent that could refuse a takeover would be an agent a person could not
    /// stop.
    pub fn operatorTakeover(control: *Control) void {
        control.controller = .operator;
    }

    /// A person hands control back to the agent.
    pub fn operatorRelease(control: *Control) void {
        // Only from operator control; a safe-stop must be reset explicitly, not
        // cleared by a release.
        if (control.controller == .operator) control.controller = .agent;
    }

    /// A safety condition trips an immediate stop. Like a takeover, it cannot be
    /// refused, and it overrides even an operator, because a safe-stop is the
    /// device protecting itself.
    pub fn tripSafeStop(control: *Control) void {
        control.controller = .safe_stop;
    }

    /// Resets a safe-stop back to agent control, after the condition is cleared.
    pub fn resetSafeStop(control: *Control) void {
        if (control.controller == .safe_stop) control.controller = .agent;
    }

    /// Decides whether an agent command may execute.
    ///
    /// The agent commands only when it holds control and the command is within
    /// the envelope. An operator takeover or a safe-stop locks it out entirely,
    /// and a command outside the envelope is refused rather than clamped, because
    /// executing a clamped version of an unsafe command still moves the device in
    /// a way nobody chose.
    pub fn command(control: Control, cmd: Command) Decision {
        switch (control.controller) {
            .operator => return .{ .refuse = .operator_in_control },
            .safe_stop => return .{ .refuse = .safe_stopped },
            .agent => {},
        }
        if (!control.envelope.boundFor(cmd.axis).contains(cmd.value)) {
            return .{ .refuse = .outside_envelope };
        }
        return .execute;
    }
};

const reference_envelope: Envelope = .{
    .velocity = .{ .min = -500, .max = 500 },
    .force = .{ .min = 0, .max = 10_000 },
    .position = .{ .min = 0, .max = 100_000 },
};

fn command(axis: Command.Axis, value: i32) Command {
    return .{ .axis = axis, .value = value };
}

test "a command within the envelope executes" {
    const control: Control = .{ .envelope = reference_envelope };
    try std.testing.expectEqual(Decision.execute, control.command(command(.velocity, 200)));
}

test "a command outside the envelope is refused, not clamped" {
    const control: Control = .{ .envelope = reference_envelope };
    // 800 mm/s exceeds the 500 limit. A clamped 500 would still move the device
    // fast; the command is refused entirely.
    try std.testing.expectEqual(
        Decision{ .refuse = .outside_envelope },
        control.command(command(.velocity, 800)),
    );
}

test "an operator takeover locks the agent out immediately" {
    var control: Control = .{ .envelope = reference_envelope };
    control.operatorTakeover();
    // Even a perfectly safe command is refused: the person is in control.
    try std.testing.expectEqual(
        Decision{ .refuse = .operator_in_control },
        control.command(command(.velocity, 0)),
    );
}

test "a person can take over from any state" {
    // The takeover guarantee: there is no state from which a person cannot seize
    // control.
    for (std.enums.values(Controller)) |initial| {
        var control: Control = .{ .envelope = reference_envelope, .controller = initial };
        control.operatorTakeover();
        try std.testing.expectEqual(Controller.operator, control.controller);
    }
}

test "releasing returns control to the agent" {
    var control: Control = .{ .envelope = reference_envelope };
    control.operatorTakeover();
    control.operatorRelease();
    try std.testing.expectEqual(Decision.execute, control.command(command(.velocity, 100)));
}

test "a safe-stop refuses all commands until reset" {
    var control: Control = .{ .envelope = reference_envelope };
    control.tripSafeStop();
    try std.testing.expectEqual(
        Decision{ .refuse = .safe_stopped },
        control.command(command(.velocity, 0)),
    );
    control.resetSafeStop();
    try std.testing.expectEqual(Decision.execute, control.command(command(.velocity, 0)));
}

test "a safe-stop overrides an operator takeover" {
    var control: Control = .{ .envelope = reference_envelope };
    control.operatorTakeover();
    control.tripSafeStop();
    // The device protecting itself wins even over a person.
    try std.testing.expectEqual(Controller.safe_stop, control.controller);
    // And a release does not clear a safe-stop.
    control.operatorRelease();
    try std.testing.expectEqual(Controller.safe_stop, control.controller);
}

test "each axis is bounded independently" {
    const control: Control = .{ .envelope = reference_envelope };
    // Force within its own bound executes even though the number would be out of
    // range for velocity.
    try std.testing.expectEqual(Decision.execute, control.command(command(.force, 8000)));
    try std.testing.expectEqual(
        Decision{ .refuse = .outside_envelope },
        control.command(command(.force, -1)),
    );
}

test "a discrete axis accepts only zero and one" {
    const control: Control = .{ .envelope = reference_envelope };
    try std.testing.expectEqual(Decision.execute, control.command(command(.discrete, 0)));
    try std.testing.expectEqual(Decision.execute, control.command(command(.discrete, 1)));
    try std.testing.expectEqual(
        Decision{ .refuse = .outside_envelope },
        control.command(command(.discrete, 2)),
    );
}

test "the envelope bounds are inclusive at their limits" {
    const control: Control = .{ .envelope = reference_envelope };
    try std.testing.expectEqual(Decision.execute, control.command(command(.velocity, 500)));
    try std.testing.expectEqual(Decision.execute, control.command(command(.velocity, -500)));
    try std.testing.expectEqual(
        Decision{ .refuse = .outside_envelope },
        control.command(command(.velocity, 501)),
    );
}

test "no agent command executes while a person is in control, swept" {
    // The property autonomy rests on: whatever the command, an operator takeover
    // means the agent commands nothing.
    var control: Control = .{ .envelope = reference_envelope };
    control.operatorTakeover();
    for ([_]Command.Axis{ .velocity, .force, .position, .discrete }) |axis| {
        try std.testing.expect(!control.command(command(axis, 0)).executes());
    }
}
