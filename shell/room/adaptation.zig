//! Deciding what a shared room display may present and touch, so a session shown on a wall can display
//! a task without granting the room access to the person's private data.
//!
//! A room display is a public surface: a screen on a wall that anyone in the room can see, often one
//! the person does not physically control. That changes two things at once. What it may *show* is
//! restricted — sensitive content is masked, because a private message on a shared wall is a leak to
//! everyone present. And what data capabilities it may *hold* are restricted — the room may present a
//! task without being granted access to the mail, messages, or personal stores behind it, because a
//! shared endpoint compromised or simply overlooked should not be a doorway into the person's private
//! data. The platform's example is exact: a room display may present a task without mail access. So the
//! room form factor presents and accepts shared input, masks sensitive content, and is denied the
//! private-data capabilities a personal surface would hold. Restricting a shared surface to public
//! content and no private-data authority is what lets a person throw a task onto a wall without
//! throwing their inbox up with it.
//!
//! This module renders nothing. It decides whether the room may show sensitive content and whether it
//! may hold a private-data capability, as pure functions.

const std = @import("std");

/// A data capability an endpoint might hold.
pub const DataCapability = enum {
    /// The task or content being presented — public to the room by intent.
    presented_task,
    /// Access to the person's mail.
    mail,
    /// Access to the person's messages.
    messages,
    /// Access to the person's private files.
    private_files,
};

/// Whether the room display may present sensitive content unmasked. It may not — it is a shared,
/// publicly visible surface, so sensitive content is always masked here.
pub fn showsSensitive() bool {
    return false;
}

/// Whether the room display may hold a given data capability.
///
/// It may hold only the capability for the task it was explicitly asked to present; the person's
/// private data stores — mail, messages, private files — are denied. So the room can show what it was
/// handed without gaining a path into everything behind it.
pub fn mayHold(capability: DataCapability) bool {
    return capability == .presented_task;
}

test "the room masks sensitive content" {
    try std.testing.expect(!showsSensitive());
}

test "the room may present its task but not reach private data" {
    try std.testing.expect(mayHold(.presented_task));
    try std.testing.expect(!mayHold(.mail));
    try std.testing.expect(!mayHold(.messages));
    try std.testing.expect(!mayHold(.private_files));
}

test "the room holds no private-data capability, swept" {
    // The shared-surface property: the only capability the room holds is the presented task itself.
    for (std.enums.values(DataCapability)) |capability| {
        if (mayHold(capability)) {
            try std.testing.expectEqual(DataCapability.presented_task, capability);
        }
    }
}
