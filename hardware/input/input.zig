//! Input event intake: touch, buttons, and the hand-off to interaction.
//!
//! Raw input is noisy — a fingertip reports many times a second, a button
//! bounces on contact — and the platform above wants events, not noise. This is
//! the policy that turns raw samples into events: it debounces a button so one
//! press is one event, coalesces a stream of touch samples so a drag is not a
//! thousand notifications, and marks every event as human-interactive so the
//! scheduler serves it ahead of background work.
//!
//! It drives no silicon. A board turns a digitizer or a GPIO into raw samples;
//! this is the shape every board shares once it has them.

const std = @import("std");

/// The kind of a raw sample.
pub const Kind = enum { touch_down, touch_move, touch_up, button_down, button_up };

/// A raw sample from the board, with the time it was observed.
pub const Sample = struct {
    kind: Kind,
    /// Milliseconds since an arbitrary but monotonic origin. Used for debounce
    /// and coalescing windows, never for wall-clock meaning.
    at_ms: u64,
    /// Which button, for button samples. Ignored for touch.
    button: u8 = 0,
};

/// An event the platform acts on, after noise is removed.
pub const Event = union(enum) {
    tap,
    drag,
    lift,
    button_press: u8,

    /// Every input event is human-interactive: a person is waiting on it, so it
    /// is served ahead of background work.
    pub fn isInteractive(event: Event) bool {
        _ = event;
        return true;
    }
};

/// What a sample produced, if anything.
pub const Result = union(enum) {
    /// An event to deliver.
    event: Event,
    /// The sample was absorbed into an in-progress gesture or bounce window.
    absorbed,
};

/// The debounce and coalescing windows, in milliseconds.
pub const Windows = struct {
    /// A second button transition within this window is a bounce, not a press.
    debounce_ms: u64 = 30,
    /// Touch-move samples within this window of the last delivered move are
    /// coalesced into the ongoing drag rather than each delivered.
    coalesce_ms: u64 = 16,

    pub const reference: Windows = .{};
};

/// The intake state for one input subsystem.
pub const Intake = struct {
    windows: Windows = Windows.reference,
    /// The last transition time per button, for debounce. Zero means never.
    last_button_ms: [8]u64 = @splat(0),
    button_down: [8]bool = @splat(false),
    /// Whether a touch contact is in progress, and when its last move was
    /// delivered, for coalescing.
    touching: bool = false,
    last_move_ms: u64 = 0,

    /// Turns one raw sample into an event or absorbs it.
    pub fn feed(intake: *Intake, sample: Sample) Result {
        return switch (sample.kind) {
            .touch_down => {
                intake.touching = true;
                intake.last_move_ms = sample.at_ms;
                return .{ .event = .tap };
            },
            .touch_move => {
                if (!intake.touching) return .absorbed;
                // Coalesce moves that arrive faster than the window.
                if (sample.at_ms -| intake.last_move_ms < intake.windows.coalesce_ms) {
                    return .absorbed;
                }
                intake.last_move_ms = sample.at_ms;
                return .{ .event = .drag };
            },
            .touch_up => {
                if (!intake.touching) return .absorbed;
                intake.touching = false;
                return .{ .event = .lift };
            },
            .button_down, .button_up => intake.button(sample),
        };
    }

    fn button(intake: *Intake, sample: Sample) Result {
        const index: usize = sample.button & 0x7;
        const going_down = sample.kind == .button_down;
        // A transition within the debounce window of the last one is a bounce.
        const last = intake.last_button_ms[index];
        if (last != 0 and sample.at_ms -| last < intake.windows.debounce_ms) {
            return .absorbed;
        }
        // Ignore a repeat in the same direction the debounce did not catch.
        if (intake.button_down[index] == going_down) return .absorbed;

        intake.last_button_ms[index] = sample.at_ms;
        intake.button_down[index] = going_down;
        if (going_down) return .{ .event = .{ .button_press = sample.button } };
        return .absorbed;
    }
};

const testing = std.testing;

test "a touch stream becomes tap, drag, lift with moves coalesced" {
    var intake: Intake = .{};
    try testing.expectEqual(Event.tap, intake.feed(.{ .kind = .touch_down, .at_ms = 0 }).event);
    // A move far enough after the last delivered move is a drag.
    try testing.expectEqual(Event.drag, intake.feed(.{ .kind = .touch_move, .at_ms = 20 }).event);
    // A move within the coalesce window is absorbed.
    try testing.expectEqual(Result.absorbed, intake.feed(.{ .kind = .touch_move, .at_ms = 28 }));
    try testing.expectEqual(Event.lift, intake.feed(.{ .kind = .touch_up, .at_ms = 40 }).event);
}

test "a bouncing button is one press" {
    var intake: Intake = .{};
    try testing.expectEqual(Event{ .button_press = 1 }, intake.feed(.{ .kind = .button_down, .at_ms = 100, .button = 1 }).event);
    // A release-and-press within the debounce window is bounce, absorbed.
    try testing.expectEqual(Result.absorbed, intake.feed(.{ .kind = .button_up, .at_ms = 110, .button = 1 }));
    try testing.expectEqual(Result.absorbed, intake.feed(.{ .kind = .button_down, .at_ms = 120, .button = 1 }));
    // A clean release well after the window is accepted (absorbed as no event).
    try testing.expectEqual(Result.absorbed, intake.feed(.{ .kind = .button_up, .at_ms = 200, .button = 1 }));
    // A fresh press after that is a new event.
    try testing.expectEqual(Event{ .button_press = 1 }, intake.feed(.{ .kind = .button_down, .at_ms = 300, .button = 1 }).event);
}

test "a move without a contact is absorbed" {
    var intake: Intake = .{};
    try testing.expectEqual(Result.absorbed, intake.feed(.{ .kind = .touch_move, .at_ms = 5 }));
}

test "every input event is interactive" {
    try testing.expect((Event{ .tap = {} }).isInteractive());
    try testing.expect((Event{ .button_press = 2 }).isInteractive());
}
