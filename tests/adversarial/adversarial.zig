//! Adversarial tests.
//!
//! Where a module's own tests ask "does the right thing happen", these ask the attacker's question:
//! given a specific attempt to defeat a security invariant, does the attempt fail? Each test names a
//! concrete attack against a decision the platform makes and asserts the decision refuses it. They sit
//! outside the modules and reach them only through the public decision each exposes, so an attack that
//! would pass here is one a real adversary could mount.
//!
//! The invariants under attack are the load-bearing ones: a path grant cannot be escaped, a phishing
//! origin cannot elicit a credential or passkey, an unreviewed install cannot proceed unacknowledged, a
//! protocol cannot be forced below its security floor, a revoked endpoint cannot keep operating,
//! synthetic input cannot become human authority, a tampered image cannot boot, and a shared surface
//! cannot reach private data. If any of these ever passes, the assertion here fails loudly.

const std = @import("std");
const applications = @import("applications");
const session = @import("session");
const emulator = @import("emulator");
const shell = @import("shell");

// No agent is special at the enforcement point: identical grants and requests yield identical
// authorization whatever mind is behind the agent.
test {
    _ = @import("agent_neutrality.zig");
}

test "attack: escape a folder grant with parent traversal" {
    // A path that climbs above the granted root must be refused, however it is dressed up.
    try std.testing.expect(!applications.files.withinGrant("../etc/secret"));
    try std.testing.expect(!applications.files.withinGrant("reports/../../escape"));
    try std.testing.expect(!applications.files.withinGrant("a/../../.."));
}

test "attack: have an agent send a message without the person" {
    // Sending is declared external, so the framework holds an agent's send for approval
    // rather than completing it on the agent's own authority.
    for (applications.messages.tools) |tool| {
        if (std.mem.eql(u8, tool.name, "message.send")) {
            try std.testing.expect(tool.effect.needsApproval());
        }
    }
}

test "attack: have an agent capture from the camera" {
    // Capture is the person's alone: it is not among the camera capabilities an agent
    // can discover or invoke at all, so no capability reaches it.
    for (applications.camera.tools) |tool| {
        try std.testing.expect(!std.mem.eql(u8, tool.name, "camera.capture"));
    }
}

test "attack: install an unreviewed package without acknowledgement" {
    // A sideloaded package must always require an explicit acknowledgement — it can
    // never proceed silently.
    try std.testing.expect(applications.store.installNeedsAcknowledgement(.sideload));
}

test "attack: force a session protocol below the security floor" {
    // Both sides could speak version 2, but the floor is 3. Negotiation must fail rather than downgrade.
    const outcome = session.protocol.negotiate(.{ .min = 1, .max = 2 }, .{ .min = 1, .max = 2 }, 3);
    try std.testing.expectEqual(session.protocol.Outcome.incompatible, outcome);
}

test "attack: keep operating from a revoked endpoint" {
    // Revocation must bite immediately: a revoked endpoint's next operation is refused.
    try std.testing.expect(!session.revocation.mayOperate(.revoked));
    try std.testing.expect(!session.revocation.mayOperate(session.revocation.revoke(.active)));
}

test "attack: claim a consequential effect twice across endpoints" {
    // The first claim wins; a second claim on the same effect must be refused, so the effect runs once.
    try std.testing.expectEqual(session.conflict.Claim.won, session.conflict.claim(false));
    try std.testing.expectEqual(session.conflict.Claim.already_claimed, session.conflict.claim(true));
}

test "attack: launder emulator-injected input into human authority" {
    // Injected input is synthetic and must never satisfy a decision requiring a present human.
    const provenance = emulator.controls.injectedProvenance();
    try std.testing.expect(!emulator.controls.mayAuthorizeAsHuman(provenance));
}

test "attack: boot a tampered image on a virtual device" {
    var authorized: emulator.image.Digest = [_]u8{0x11} ** 32;
    var tampered = authorized;
    tampered[0] ^= 0x80; // Flip one bit.
    try std.testing.expect(!emulator.image.mayBoot(tampered, authorized));
    _ = &authorized;
}

test "attack: reach private data from a shared room display" {
    // A room display holds only the presented task; mail, messages, and private files are denied.
    try std.testing.expect(!shell.room.mayHold(.mail));
    try std.testing.expect(!shell.room.mayHold(.messages));
    try std.testing.expect(!shell.room.mayHold(.private_files));
    // And it never shows sensitive content.
    try std.testing.expect(!shell.room.showsSensitive());
}

test "attack: install applications from a wearable" {
    // The wearable may approve but must never install.
    try std.testing.expect(!shell.wearable.permits(.install));
}

test "attack: read private contact fields with only basic scope" {
    // A grant covering only the name never yields a private field, however the read
    // is phrased.
    var basic: applications.contacts.FieldSet = .initEmpty();
    basic.insert(.name);
    try std.testing.expect(!applications.contacts.fieldVisible(basic, .address));
    try std.testing.expect(!applications.contacts.fieldVisible(basic, .birthday));
    // An empty grant yields nothing at all.
    const none: applications.contacts.FieldSet = .initEmpty();
    try std.testing.expect(!applications.contacts.fieldVisible(none, .email));
}
