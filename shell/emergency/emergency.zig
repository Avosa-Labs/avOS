//! Deciding which emergency actions a locked device offers without unlocking, so help is one
//! reach away when the person may be unable to authenticate.
//!
//! The emergency surface exists for the moment when seconds matter and the person holding the
//! device may not be its owner — a bystander helping someone unconscious, or the owner in a
//! state where entering a passcode is impossible. Life-safety actions must therefore work
//! straight from the lock screen: placing an emergency call, triggering an SOS, and displaying
//! the medical ID that first responders need. Those reveal only what is necessary to get help
//! and take no action against the owner's interests, so the lock does not gate them. Anything
//! that would expose unrelated private data — the call history, messages, photos — stays locked,
//! because an emergency is not a general key to the device. So the surface is reachable while
//! locked, and each action decides for itself whether saving a life outweighs the lock.
//!
//! This module dials nothing. It decides whether an emergency action is available while locked,
//! from what the action does, as a pure function over the action kind.

const std = @import("std");

/// An action reachable from the emergency surface, which decides whether the lock gates it.
pub const Action = enum {
    /// Place a call to emergency services. Life-safety; always available while locked.
    emergency_call,
    /// Trigger the SOS alert to contacts and services. Life-safety; always available.
    trigger_sos,
    /// Show the medical ID first responders need. Life-safety; always available.
    show_medical_id,
    /// Open the full call history — unrelated private data. Requires unlock.
    view_call_history,
    /// Open messages — unrelated private data. Requires unlock.
    view_messages,
};

/// Whether an emergency action is available while the device is locked.
///
/// The emergency call, the SOS trigger, and the medical ID are life-safety actions: they may be
/// needed by someone who cannot unlock the device, so the lock must never stand between the
/// person and help. Actions that merely reveal unrelated private data — call history, messages —
/// are not emergencies at all and stay behind the lock, so the surface cannot be misused as a
/// bypass. The default for anything that is not a life-safety action is to require unlock.
pub fn availableWhileLocked(action: Action) bool {
    return switch (action) {
        .emergency_call, .trigger_sos, .show_medical_id => true,
        .view_call_history, .view_messages => false,
    };
}

test "life-safety actions are available while locked" {
    try std.testing.expect(availableWhileLocked(.emergency_call));
    try std.testing.expect(availableWhileLocked(.trigger_sos));
    try std.testing.expect(availableWhileLocked(.show_medical_id));
}

test "actions revealing unrelated private data require unlock" {
    try std.testing.expect(!availableWhileLocked(.view_call_history));
    try std.testing.expect(!availableWhileLocked(.view_messages));
}

test "no action that exposes unrelated private data is ever reachable while locked, swept" {
    // The bypass-integrity property: while locked, only the three life-safety actions are
    // available, so the emergency surface can never serve as a route around the lock.
    for (std.enums.values(Action)) |action| {
        if (availableWhileLocked(action)) {
            switch (action) {
                .emergency_call, .trigger_sos, .show_medical_id => {},
                else => try std.testing.expect(false),
            }
        }
    }
}
