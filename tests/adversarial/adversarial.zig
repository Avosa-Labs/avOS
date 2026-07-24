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

test "attack: escape a folder grant with parent traversal" {
    // A path that climbs above the granted root must be refused, however it is dressed up.
    try std.testing.expect(!applications.files.withinGrant(&.{ "..", "etc", "secret" }));
    try std.testing.expect(!applications.files.withinGrant(&.{ "reports", "..", "..", "escape" }));
    try std.testing.expect(!applications.files.withinGrant(&.{ "a", "..", "..", ".." }));
}

test "attack: elicit a saved credential from a look-alike origin" {
    const saved = applications.browser.Origin{ .scheme = "https", .host = "bank.example" };
    const homograph = applications.browser.Origin{ .scheme = "https", .host = "bank.example.evil" };
    // Even over a secure connection, a mismatched host gets nothing.
    try std.testing.expect(!applications.browser.mayOffer(saved, homograph, true));
    // And the real host over an insecure connection also gets nothing.
    const insecure = applications.browser.Origin{ .scheme = "http", .host = "bank.example" };
    try std.testing.expect(!applications.browser.mayOffer(saved, insecure, false));
}

test "attack: present a passkey to a phishing relying party" {
    const request = applications.credentials.Request{
        .registered_rp = "bank.example",
        .requesting_origin = "bank.example.evil",
        .connection_secure = true,
    };
    try std.testing.expect(!applications.credentials.mayOffer(request));
}

test "attack: install an unreviewed package without acknowledgement" {
    // An external package that was never acknowledged must not reach a proceed decision.
    const decision = applications.store.decide(.external, false);
    try std.testing.expect(decision != .proceed);
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
    try std.testing.expect(!applications.contacts.mayRead(.basic, .private));
    try std.testing.expect(!applications.contacts.mayRead(.none, .identifying));
}
