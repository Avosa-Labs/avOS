//! Deciding whether an endpoint may attach to a Personal Compute Instance, so a session is joined
//! only by a device the instance's owner authorized, and never with more authority than it was
//! granted.
//!
//! An instance is a person's environment, and an endpoint asking to attach is asking to become a
//! window into it. That request has to be authenticated to the instance's owner: an endpoint
//! presenting a credential bound to a different human is not a window into this instance at all, and
//! is refused before anything is shown. Beyond authentication, attaching does not confer authority —
//! an endpoint attaches with exactly the permissions it was granted, and an endpoint permitted only
//! to present cannot, by attaching, gain the ability to act. The two checks are separate on purpose:
//! the first stops the wrong person's device from ever seeing the instance, the second stops a device
//! that may legitimately watch from being able to do things. An attach that clears authentication is
//! admitted at its granted permission level and no higher, which is what lets a person add a
//! borrowed or shared screen to their session without that screen being able to act as them.
//!
//! This module attaches nothing. It decides whether an attach is admitted and at what authority,
//! from the endpoint's credential and granted permissions, as pure functions.

const std = @import("std");

/// What an endpoint was granted over an instance it attaches to.
pub const Permissions = struct {
    /// May render the instance.
    may_present: bool,
    /// May send input — act as the authenticated human.
    may_act: bool,
};

/// An endpoint's request to attach to an instance.
pub const Attach = struct {
    /// The human the attaching endpoint's credential authenticates to.
    credential_human: u64,
    /// The human who owns the instance being joined.
    instance_owner: u64,
    /// The permissions the endpoint was granted.
    granted: Permissions,
};

/// The outcome of an attach request.
pub const Admission = union(enum) {
    /// The attach is admitted at the given permission level.
    admitted: Permissions,
    /// The attach is refused because the credential is for a different human.
    refused_wrong_owner,
};

/// Decides whether an attach is admitted, and at what authority.
///
/// The endpoint's credential must authenticate to the instance's owner; if it does not, the attach
/// is refused outright and nothing is shown. If it does, the attach is admitted at exactly the
/// granted permissions — never elevated. Attaching therefore verifies who, then applies what, and the
/// what can only be what the owner already granted.
pub fn admit(attach: Attach) Admission {
    if (attach.credential_human != attach.instance_owner) return .refused_wrong_owner;
    return .{ .admitted = attach.granted };
}

fn makeAttach(credential: u64, owner: u64, present: bool, act: bool) Attach {
    return .{
        .credential_human = credential,
        .instance_owner = owner,
        .granted = .{ .may_present = present, .may_act = act },
    };
}

test "an endpoint authenticated to the owner is admitted at its granted level" {
    const outcome = admit(makeAttach(7, 7, true, false));
    try std.testing.expectEqual(Admission{ .admitted = .{ .may_present = true, .may_act = false } }, outcome);
}

test "an endpoint for a different human is refused" {
    try std.testing.expectEqual(Admission.refused_wrong_owner, admit(makeAttach(8, 7, true, true)));
}

test "attaching never elevates authority above the grant, swept" {
    // The no-elevation property: an admitted attach carries exactly the permissions granted, and a
    // wrong-owner attach is never admitted at all.
    for ([_]bool{ false, true }) |present| {
        for ([_]bool{ false, true }) |act| {
            const same = admit(makeAttach(7, 7, present, act));
            try std.testing.expectEqual(Admission{ .admitted = .{ .may_present = present, .may_act = act } }, same);
            const other = admit(makeAttach(9, 7, present, act));
            try std.testing.expectEqual(Admission.refused_wrong_owner, other);
        }
    }
}
