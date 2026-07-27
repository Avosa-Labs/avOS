//! The status chip (pill): the shared component that states what is happening to an element —
//! running, done, denied — and, in agent-violet, that an agent is the one touching it.
//!
//! Every surface repeats the same few status pills, so their colour and meaning are decided once
//! here rather than drifting per app. The agent chip is the visual signature of co-habitation: it
//! is always the same violet, whichever agent is acting — a cloud model, a local model, or a robot
//! — because it is a system statement about who is acting, never a slot for a vendor's colour. This
//! module maps a status to its label, its colour from the design tokens, and whether it pulses
//! (live agent activity, so co-habitation reads in motion and not only in colour). It draws
//! nothing; a surface renders the pill from this.

const std = @import("std");
const theme = @import("../theme/theme.zig");

pub const Colour = theme.Colour;

/// What a chip states about the element it sits on.
pub const Status = enum {
    /// An agent is acting on this element — the co-habitation signature.
    agent,
    /// Live agent activity, happening right now; it pulses.
    live,
    /// Work is running.
    running,
    /// The action completed.
    done,
    /// The action is held for a person's approval.
    awaiting,
    /// The action was refused.
    denied,
    /// The action failed after it had started.
    failed,
    /// The action was cancelled.
    cancelled,
};

/// A status chip: a status, and the label, colour, and motion a surface renders it with.
pub const Chip = struct {
    status: Status,

    pub fn label(chip: Chip) []const u8 {
        return switch (chip.status) {
            .agent => "Agent",
            .live => "Live",
            .running => "Running",
            .done => "Done",
            .awaiting => "Hold",
            .denied => "Denied",
            .failed => "Failed",
            .cancelled => "Cancelled",
        };
    }

    /// The chip's colour, from the design tokens. Agent and live are the one agent-violet — a
    /// system statement, not brand-styleable through a chip; the rest carry status meaning.
    pub fn colour(chip: Chip) Colour {
        return switch (chip.status) {
            .agent, .live => theme.agent,
            .running => theme.human,
            .done => theme.teal,
            .awaiting => theme.amber,
            .denied => theme.denied,
            .failed => theme.coral,
            .cancelled => theme.text_tertiary,
        };
    }

    /// Whether the chip pulses. Live agent activity breathes so a person sees an agent at work in
    /// motion, not only in colour; a reduced-motion setting substitutes a calm variant elsewhere.
    pub fn pulses(chip: Chip) bool {
        return chip.status == .live or chip.status == .agent;
    }
};

// --- Tests ---

const testing = std.testing;

test "the agent and live chips are the one agent-violet, and both pulse" {
    try testing.expect(std.meta.eql((Chip{ .status = .agent }).colour(), theme.agent));
    try testing.expect(std.meta.eql((Chip{ .status = .live }).colour(), theme.agent));
    try testing.expect((Chip{ .status = .agent }).pulses());
    try testing.expect((Chip{ .status = .live }).pulses());
}

test "a status chip carries its status colour and does not pulse" {
    try testing.expect(std.meta.eql((Chip{ .status = .denied }).colour(), theme.denied));
    try testing.expect(std.meta.eql((Chip{ .status = .done }).colour(), theme.teal));
    try testing.expect(std.meta.eql((Chip{ .status = .awaiting }).colour(), theme.amber));
    try testing.expect(!(Chip{ .status = .running }).pulses());
    try testing.expect(!(Chip{ .status = .done }).pulses());
}

test "every status has a non-empty label and resolves a colour" {
    inline for (std.meta.fields(Status)) |field| {
        const chip = Chip{ .status = @enumFromInt(field.value) };
        try testing.expect(chip.label().len > 0);
        _ = chip.colour();
    }
}
