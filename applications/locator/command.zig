//! Deciding whether a remote command to a lost device is obeyed, so the owner can still locate,
//! lock, or erase it while a thief holding the hardware cannot countermand them.
//!
//! When a device is lost, control has to survive the loss: the owner, from somewhere else, must be
//! able to find it, lock it, or wipe it, and whoever now physically holds it must be able to do none
//! of those. The two requirements meet at authentication. A remote command is obeyed only when it
//! carries a valid authorization from the device's owner account — the credential the finder does not
//! have — regardless of the device being unlocked, in someone else's hands, or put into a "found"
//! state. A command without that authorization is ignored, because on a lost device an unauthenticated
//! instruction is exactly what an attacker would send to disable tracking or cancel a wipe. The
//! device keeps obeying its owner and only its owner, which is what lets remote erase be a real
//! last resort: the person who lost the device can still reach across and destroy its data, and the
//! person who found it cannot stop them.
//!
//! This module sends no command. It decides whether a remote command is obeyed, from whether it
//! carries valid owner authorization, as a pure function.

const std = @import("std");

/// A remote command that may be sent to a lost device.
pub const Command = enum {
    /// Report the device's location to the owner.
    locate,
    /// Lock the device.
    lock,
    /// Erase the device's data.
    erase,
    /// Turn off lost-device tracking.
    disable_tracking,
};

/// Whether a remote command is obeyed.
///
/// A command is obeyed only when it carries valid authorization from the owner account. This holds
/// for every command, including the destructive erase and the protection-removing disable: none is
/// honoured without owner authorization, so a finder or thief cannot issue any of them, and the owner
/// can issue all of them from afar.
pub fn obey(command: Command, owner_authorized: bool) bool {
    _ = command;
    return owner_authorized;
}

test "an authorized owner command is obeyed" {
    try std.testing.expect(obey(.erase, true));
    try std.testing.expect(obey(.locate, true));
}

test "an unauthorized command is ignored" {
    try std.testing.expect(!obey(.disable_tracking, false));
    try std.testing.expect(!obey(.erase, false));
}

test "no command is ever obeyed without owner authorization, swept" {
    // The owner-only-control property: any obeyed command carried owner authorization.
    for (std.enums.values(Command)) |command| {
        for ([_]bool{ false, true }) |authorized| {
            if (obey(command, authorized)) {
                try std.testing.expect(authorized);
            }
        }
    }
}
