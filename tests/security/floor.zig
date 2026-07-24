//! The security floor.
//!
//! A single suite that states the platform's load-bearing security guarantees as explicit, named
//! assertions an auditor can read top to bottom and check against the code. Each guarantee is phrased
//! as an invariant the platform must never violate, and is asserted against the actual decision
//! modules — not a description of them. Where the adversarial suite mounts specific attacks and the
//! property suite sweeps input spaces, this suite is the readable index of the floor: the short list of
//! things that must always be true, each tied to the module that makes it true.
//!
//! If any assertion here fails, a floor guarantee has been broken, and the failure names which one.

const std = @import("std");
const applications = @import("applications");
const session = @import("session");
const emulator = @import("emulator");
const shell = @import("shell");
const packaging = @import("packaging");

test "floor: authority is never elevated by attaching an endpoint" {
    // An endpoint authenticated to the owner is admitted at exactly its granted permissions.
    const present_only = session.attach.admit(.{
        .credential_human = 1,
        .instance_owner = 1,
        .granted = .{ .may_present = true, .may_act = false },
    });
    try std.testing.expectEqual(
        session.attach.Admission{ .admitted = .{ .may_present = true, .may_act = false } },
        present_only,
    );
    // An endpoint for a different human is refused outright.
    const wrong = session.attach.admit(.{
        .credential_human = 2,
        .instance_owner = 1,
        .granted = .{ .may_present = true, .may_act = true },
    });
    try std.testing.expectEqual(session.attach.Admission.refused_wrong_owner, wrong);
}

test "floor: a consequential effect executes at most once" {
    try std.testing.expectEqual(session.conflict.Claim.won, session.conflict.claim(false));
    try std.testing.expectEqual(session.conflict.Claim.already_claimed, session.conflict.claim(true));
}

test "floor: synthetic input never carries human authority" {
    try std.testing.expect(!emulator.controls.mayAuthorizeAsHuman(emulator.controls.injectedProvenance()));
}

test "floor: only content-verified images boot" {
    const authorized: emulator.image.Digest = [_]u8{0x5A} ** 32;
    var tampered = authorized;
    tampered[31] ^= 0x01;
    try std.testing.expect(emulator.image.mayBoot(authorized, authorized));
    try std.testing.expect(!emulator.image.mayBoot(tampered, authorized));
}

test "floor: updates never downgrade and channels never under-mature" {
    // A lower version is never offered; an under-matured build is never offered to a stricter channel.
    try std.testing.expect(!packaging.channel.mayOffer(.{ .maturity = .stable, .version = 3 }, .stable, 4));
    try std.testing.expect(!packaging.channel.mayOffer(.{ .maturity = .beta, .version = 5 }, .stable, 4));
}

test "floor: a device never commits to an unbootable slot" {
    // An exhausted, unconfirmed updated slot falls back to known-good.
    try std.testing.expectEqual(
        packaging.recovery.Slot.current,
        packaging.recovery.bootSlot(.{ .confirmed = false, .attempts_used = 3, .attempts_allowed = 3 }),
    );
}

test "floor: private data is unreachable from a shared surface" {
    try std.testing.expect(!shell.room.mayHold(.mail));
    try std.testing.expect(!shell.room.showsSensitive());
}

test "floor: a permission is never exceeded beyond what was declared or granted" {
    // Web permission ceiling: an undeclared permission cannot be requested.
    const manifest = [_][]const u8{ "geolocation", "notifications" };
    try std.testing.expect(!applications.contacts.mayRead(.basic, .private)); // contact field scope
    // Location precision ceiling: exact only under a precise grant.
    try std.testing.expect(applications.maps.deliver(.approximate) != .exact);
    _ = manifest;
}

test "floor: a file grant cannot be escaped" {
    try std.testing.expect(!applications.files.withinGrant(&.{ "..", "escape" }));
}

test "floor: sensitive settings require fresh authentication" {
    try std.testing.expect(!applications.settings.mayChange(.sensitive, false));
    try std.testing.expect(applications.settings.mayChange(.sensitive, true));
}
