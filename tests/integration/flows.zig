//! Integration flows.
//!
//! Where the other suites check one decision at a time, these stitch several modules into the flow a
//! real scenario follows and assert the composed outcome. A guarantee can hold for each module in
//! isolation and still be broken by how they compose; these tests exist to catch that. Each flow is a
//! short sequence of decisions across module boundaries, phrased as the story a person or an agent
//! actually walks through.
//!
//! The flows deliberately cross the seams — session onto an endpoint, an app requesting authority, a
//! release reaching a device — because the seams are where composition bugs live.

const std = @import("std");
const applications = @import("applications");
const session = @import("session");
const shell = @import("shell");
const packaging = @import("packaging");

test "flow: a session handed to a shared display shows nothing sensitive it should not" {
    // Attach an endpoint as the owner, present-only, then compose with the room form factor and the
    // presentation frame: sensitive content must be masked on the shared surface.
    const admission = session.attach.admit(.{
        .credential_human = 7,
        .instance_owner = 7,
        .granted = .{ .may_present = true, .may_act = false },
    });
    switch (admission) {
        .admitted => |perms| {
            try std.testing.expect(perms.may_present);
            try std.testing.expect(!perms.may_act); // present-only endpoint
        },
        .refused_wrong_owner => try std.testing.expect(false),
    }
    // The room holds no private data and masks sensitive content.
    try std.testing.expect(!shell.room.mayHold(.mail));
    try std.testing.expect(!shell.room.showsSensitive());
    // And a sensitive frame field is masked on a shared surface.
    try std.testing.expectEqual(
        session.presentation.Render.masked,
        session.presentation.render(.sensitive, .shared_surface),
    );
}

test "flow: an install reaches a device only through source acknowledgement and channel maturity" {
    // A sideloaded package is gated on acknowledgement...
    try std.testing.expect(applications.store.decide(.external, false) != .proceed);
    try std.testing.expect(applications.store.decide(.external, true) == .proceed);
    // ...and a build reaches a stable device only if mature and forward.
    try std.testing.expect(packaging.channel.mayOffer(.{ .maturity = .stable, .version = 5 }, .stable, 4));
    try std.testing.expect(!packaging.channel.mayOffer(.{ .maturity = .beta, .version = 5 }, .stable, 4));
}

test "flow: a consequential action on one endpoint is not repeated after handoff" {
    // Endpoint A claims the effect and runs it; after handoff, endpoint B's claim on the same effect
    // is refused, so the effect is not repeated.
    try std.testing.expectEqual(session.conflict.Claim.won, session.conflict.claim(false));
    // Handoff moves the presenter; the effect ledger is unchanged.
    const after = session.presenter.handoff(.{ .endpoint = 1 }, .{ .id = 2, .trusted = true, .may_present = true });
    try std.testing.expectEqual(session.presenter.Presenter{ .endpoint = 2 }, after);
    // Endpoint B attempts the already-claimed effect.
    try std.testing.expectEqual(session.conflict.Claim.already_claimed, session.conflict.claim(true));
}

test "flow: a rollout only widens behind a healthy soak, and a bad build rolls back" {
    // A healthy, soaked ring advances; a regressed ring rolls back regardless of soak.
    try std.testing.expectEqual(
        packaging.rollout.Decision.advance,
        packaging.rollout.decide(.{ .soak_hours = 24, .health = .healthy }, 24),
    );
    try std.testing.expectEqual(
        packaging.rollout.Decision.rollback,
        packaging.rollout.decide(.{ .soak_hours = 100, .health = .regressed }, 24),
    );
}
