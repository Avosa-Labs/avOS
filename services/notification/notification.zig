//! Deciding whether a notification interrupts a person, is shown quietly, or is
//! withheld.
//!
//! A notification is an interruption, and interruption is a cost a device spends
//! on a person's attention. Spent carelessly it is how a phone becomes something
//! a person dreads: the same alert three times because an app retried, a
//! marketing ping during a meeting, a buzz at three in the morning for something
//! that could have waited. So delivery is not "show it because something asked".
//! It is a decision about whether this notification, at this priority, is worth
//! interrupting for right now, and the same content arriving twice is recognized
//! as one thing rather than delivered twice.
//!
//! This module makes that decision. It holds no queue and draws no banner; given
//! a notification's priority, the person's current focus state, and what was
//! recently shown, it answers how the notification should be delivered — as an
//! interruption, silently, or not at all. The rule is testable across focus
//! states and repeat patterns a real day would take hours to produce.

const std = @import("std");

/// How much a notification is allowed to interrupt.
///
/// Ordered, because focus rules gate by priority: a focus mode that silences
/// everything below a threshold needs the threshold to be comparable.
pub const Priority = enum(u8) {
    /// Background information. Shown in a list, never interrupts.
    passive = 0,
    /// Ordinary: a message, an update. Interrupts when the person is available.
    standard = 1,
    /// Time-sensitive: a ride arriving, a reminder due right away. Interrupts through
    /// most focus modes.
    time_sensitive = 2,
    /// Critical: an alarm, an emergency alert, a security warning. Interrupts
    /// through everything, including do-not-disturb, because withholding it
    /// could cause harm.
    critical = 3,

    pub fn isAtLeast(priority: Priority, floor: Priority) bool {
        return @intFromEnum(priority) >= @intFromEnum(floor);
    }
};

/// The person's current availability for interruption.
pub const Focus = enum {
    /// Available. Standard and above interrupt.
    available,
    /// Focused on something: work, reading, driving. Only time-sensitive and
    /// above interrupt; the rest wait quietly.
    focused,
    /// Do not disturb: sleeping, in a meeting. Only critical interrupts;
    /// everything else is silent.
    do_not_disturb,

    /// The lowest priority that may interrupt in this focus state.
    ///
    /// This is where the person's chosen quiet is honoured: a higher focus
    /// raises the bar, and only critical clears the highest bar, because a
    /// critical alert withheld could be a harm.
    pub fn interruptionFloor(focus: Focus) Priority {
        return switch (focus) {
            .available => .standard,
            .focused => .time_sensitive,
            .do_not_disturb => .critical,
        };
    }
};

/// How a notification should be delivered.
pub const Delivery = enum {
    /// Interrupt: sound or vibration, a banner. The person is meant to notice
    /// now.
    interrupt,
    /// Show it, but quietly: no sound, it waits in a list. Seen when the person
    /// looks, not pushed at them.
    silent,
    /// Do not deliver at all. A duplicate of something just shown.
    suppress,
};

/// A notification offered for delivery.
pub const Notification = struct {
    priority: Priority,
    /// Identifies what this notification is about, so a repeat of the same thing
    /// can be recognized. Two notifications with the same key are the same
    /// event, however many times an app submits it.
    dedup_key: u64,
    /// When it was submitted, in milliseconds.
    at_ms: u64,
};

/// How long a notification of a given key suppresses repeats, in milliseconds.
///
/// A window, not forever: an update an hour later is worth showing again, but
/// three retries in a second are one notification.
pub const dedup_window_ms: u64 = 30_000;

/// The last delivery of each key the decider remembers, for deduplication.
pub const Recent = struct {
    const Slot = struct {
        key: u64,
        at_ms: u64,
    };

    /// A small ring of recently delivered keys. Bounded, because a notification
    /// decider on a busy device must not accumulate an unbounded history.
    slots: [64]?Slot = @splat(null),
    next: usize = 0,

    /// Whether a key was delivered within the dedup window ending at `now_ms`.
    fn wasRecentlyDelivered(recent: Recent, key: u64, now_ms: u64) bool {
        for (recent.slots) |slot| {
            const present = slot orelse continue;
            if (present.key != key) continue;
            if (now_ms >= present.at_ms and now_ms - present.at_ms < dedup_window_ms) return true;
        }
        return false;
    }

    /// Records that a key was delivered.
    fn record(recent: *Recent, key: u64, at_ms: u64) void {
        recent.slots[recent.next] = .{ .key = key, .at_ms = at_ms };
        recent.next = (recent.next + 1) % recent.slots.len;
    }
};

/// Decides how a notification should be delivered.
///
/// A repeat of something shown within the window is suppressed, whatever its
/// priority, because delivering the same thing twice is noise. Otherwise the
/// priority is weighed against the focus floor: at or above the floor it
/// interrupts, below it is shown silently rather than dropped, because a person
/// should still find it when they look even if it did not earn an interruption.
/// Critical always interrupts, because the one thing worse than an unwanted
/// interruption is a withheld emergency.
pub fn decide(notification: Notification, focus: Focus, recent: *Recent) Delivery {
    // Deduplicate first: a repeat is not re-delivered even at high priority,
    // except critical, which may legitimately re-fire (an alarm snooze, an
    // escalating alert).
    if (notification.priority != .critical and
        recent.wasRecentlyDelivered(notification.dedup_key, notification.at_ms))
    {
        return .suppress;
    }

    const delivery: Delivery = if (notification.priority.isAtLeast(focus.interruptionFloor()))
        .interrupt
    else
        .silent;

    // Record only what is actually shown, so a suppressed duplicate does not
    // extend the window and a silent one still deduplicates future repeats.
    if (delivery != .suppress) recent.record(notification.dedup_key, notification.at_ms);
    return delivery;
}

fn notif(priority: Priority, key: u64, at_ms: u64) Notification {
    return .{ .priority = priority, .dedup_key = key, .at_ms = at_ms };
}

test "a standard notification interrupts when the person is available" {
    var recent: Recent = .{};
    try std.testing.expectEqual(
        Delivery.interrupt,
        decide(notif(.standard, 1, 1000), .available, &recent),
    );
}

test "focus silences standard but not time-sensitive" {
    var recent: Recent = .{};
    // Focused: standard waits quietly, time-sensitive still interrupts.
    try std.testing.expectEqual(Delivery.silent, decide(notif(.standard, 1, 1000), .focused, &recent));
    try std.testing.expectEqual(
        Delivery.interrupt,
        decide(notif(.time_sensitive, 2, 1000), .focused, &recent),
    );
}

test "do-not-disturb silences everything but critical" {
    var recent: Recent = .{};
    try std.testing.expectEqual(
        Delivery.silent,
        decide(notif(.time_sensitive, 1, 1000), .do_not_disturb, &recent),
    );
    // Critical interrupts through do-not-disturb, because withholding it could
    // be a harm.
    try std.testing.expectEqual(
        Delivery.interrupt,
        decide(notif(.critical, 2, 1000), .do_not_disturb, &recent),
    );
}

test "a duplicate within the window is suppressed" {
    var recent: Recent = .{};
    // Same key twice in quick succession: the second is an app retry, not a
    // second event.
    try std.testing.expectEqual(Delivery.interrupt, decide(notif(.standard, 7, 1000), .available, &recent));
    try std.testing.expectEqual(Delivery.suppress, decide(notif(.standard, 7, 1100), .available, &recent));
}

test "the same key after the window is shown again" {
    var recent: Recent = .{};
    try std.testing.expectEqual(Delivery.interrupt, decide(notif(.standard, 7, 1000), .available, &recent));
    // An hour later — past the window — is a genuinely new occurrence.
    try std.testing.expectEqual(
        Delivery.interrupt,
        decide(notif(.standard, 7, 1000 + dedup_window_ms), .available, &recent),
    );
}

test "a critical notification is never suppressed as a duplicate" {
    var recent: Recent = .{};
    // An alarm may legitimately re-fire; critical is exempt from dedup.
    try std.testing.expectEqual(Delivery.interrupt, decide(notif(.critical, 9, 1000), .available, &recent));
    try std.testing.expectEqual(Delivery.interrupt, decide(notif(.critical, 9, 1100), .available, &recent));
}

test "a silent notification still deduplicates future repeats" {
    var recent: Recent = .{};
    // Shown silently under focus, then repeated: the repeat is still a
    // duplicate.
    try std.testing.expectEqual(Delivery.silent, decide(notif(.standard, 5, 1000), .focused, &recent));
    try std.testing.expectEqual(Delivery.suppress, decide(notif(.standard, 5, 1100), .focused, &recent));
}

test "a suppressed duplicate does not extend the dedup window" {
    var recent: Recent = .{};
    // First delivery at t=1000, so the window ends at 31000.
    _ = decide(notif(.standard, 3, 1000), .available, &recent);
    // A duplicate at 20000 is suppressed but must not reset the window.
    try std.testing.expectEqual(Delivery.suppress, decide(notif(.standard, 3, 20000), .available, &recent));
    // Just past the original window, it delivers again — the suppressed repeat
    // did not push the window out.
    try std.testing.expectEqual(
        Delivery.interrupt,
        decide(notif(.standard, 3, 1000 + dedup_window_ms + 1), .available, &recent),
    );
}

test "passive notifications never interrupt, even when available" {
    var recent: Recent = .{};
    // Below the standard floor, so shown in a list rather than pushed.
    try std.testing.expectEqual(Delivery.silent, decide(notif(.passive, 1, 1000), .available, &recent));
}

test "the interruption floor rises with focus" {
    try std.testing.expectEqual(Priority.standard, Focus.available.interruptionFloor());
    try std.testing.expectEqual(Priority.time_sensitive, Focus.focused.interruptionFloor());
    try std.testing.expectEqual(Priority.critical, Focus.do_not_disturb.interruptionFloor());
}

test "critical clears every focus floor" {
    // Swept: whatever the focus, critical interrupts.
    var recent: Recent = .{};
    for (std.enums.values(Focus)) |focus| {
        var fresh: Recent = .{};
        try std.testing.expectEqual(
            Delivery.interrupt,
            decide(notif(.critical, 1, 1000), focus, &fresh),
        );
    }
    _ = &recent;
}
