//! The plan step: one line of an agent's plan, and the plan as an ordered list of them.
//!
//! The reference design shows an agent's work as a plan unfolding — "Calendar checked" done,
//! "Route planning" running, "Pay hotel deposit" held for the person. This is that row and that
//! list: each step is a label and a status, coloured by the same status mapping the chip and the
//! list-row use, so the plan reads in one glance and a held step stands out as the one waiting on a
//! decision. It draws nothing; a surface lays the steps out, and the held step is where the
//! approval sheet is offered.

const std = @import("std");
const status_chip = @import("status_chip.zig");
const theme = @import("../theme/theme.zig");

pub const Colour = theme.Colour;
pub const Status = status_chip.Status;

/// One step of a plan: what it is, and where it stands.
pub const Step = struct {
    label: []const u8,
    status: Status,

    /// The step's colour, from the same status mapping the rest of the library uses.
    pub fn colour(step: Step) Colour {
        return (status_chip.Chip{ .status = step.status }).colour();
    }

    /// Whether the step is waiting on the person — the point the approval sheet attaches to.
    pub fn isHeld(step: Step) bool {
        return step.status == .awaiting;
    }

    /// Whether the step is being worked right now.
    pub fn isActive(step: Step) bool {
        return step.status == .running or step.status == .live;
    }
};

/// An agent's plan: its steps in order.
pub const Plan = struct {
    steps: []const Step,

    /// The index of the first step held for the person, or null if none is. A plan pauses at its
    /// held step until the person decides.
    pub fn heldStep(plan: Plan) ?usize {
        for (plan.steps, 0..) |step, i| {
            if (step.isHeld()) return i;
        }
        return null;
    }

    /// Whether every step has completed.
    pub fn allDone(plan: Plan) bool {
        for (plan.steps) |step| {
            if (step.status != .done) return false;
        }
        return true;
    }
};

// --- Tests ---

const testing = std.testing;

test "the reference design's Lisbon plan reads by status" {
    const steps = [_]Step{
        .{ .label = "Calendar checked", .status = .done },
        .{ .label = "Inbox scanned", .status = .done },
        .{ .label = "Route planning", .status = .running },
        .{ .label = "Pay hotel deposit", .status = .awaiting },
    };
    const plan = Plan{ .steps = &steps };

    try testing.expect(!plan.allDone()); // work remains
    try testing.expectEqual(@as(?usize, 3), plan.heldStep()); // the deposit waits on the person
    try testing.expect(steps[2].isActive()); // route planning is running
    try testing.expect(steps[3].isHeld());
    try testing.expect(std.meta.eql(steps[3].colour(), theme.amber)); // a held step is the awaiting amber
}

test "a finished plan reports all done and holds nothing" {
    const steps = [_]Step{
        .{ .label = "Booked", .status = .done },
        .{ .label = "Confirmed", .status = .done },
    };
    const plan = Plan{ .steps = &steps };
    try testing.expect(plan.allDone());
    try testing.expect(plan.heldStep() == null);
}
