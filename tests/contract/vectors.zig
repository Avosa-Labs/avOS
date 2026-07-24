//! Contract-vector conformance.
//!
//! The `test-vectors/` directories state, in text, the outcomes any implementation of a boundary must
//! produce. This suite ties a representative slice of those documented vectors to the actual decision
//! modules, so the code and the contract cannot drift apart silently: if a module's decision stops
//! matching the vector table that describes it, an assertion here fails. It is the executable half of
//! the shared-vector contract — the tables are what an outside implementer reads, and these tests are
//! what proves this implementation honors them.
//!
//! Each test names the vector file and the specific vectors it checks, so a failure points at the exact
//! contract entry that no longer holds.

const std = @import("std");
const session = @import("session");
const packaging = @import("packaging");
const emulator = @import("emulator");

test "session vectors: negotiate-overlap and negotiate-below-floor" {
    // test-vectors/session: negotiate [2,4]&[3,6] floor 1 → agree 4; best 2 floor 3 → incompatible.
    try std.testing.expectEqual(
        session.protocol.Outcome{ .agreed = 4 },
        session.protocol.negotiate(.{ .min = 2, .max = 4 }, .{ .min = 3, .max = 6 }, 1),
    );
    try std.testing.expectEqual(
        session.protocol.Outcome.incompatible,
        session.protocol.negotiate(.{ .min = 1, .max = 2 }, .{ .min = 1, .max = 2 }, 3),
    );
}

test "session vectors: state-current and state-stale" {
    // test-vectors/session: current-based update accepted, version+1; earlier-based update stale.
    try std.testing.expectEqual(
        session.state.Result{ .accepted = 11 },
        session.state.apply(10, .{ .base_version = 10 }),
    );
    try std.testing.expectEqual(
        session.state.Result.stale,
        session.state.apply(10, .{ .base_version = 8 }),
    );
}

test "session vectors: revoke-immediate" {
    // test-vectors/session: a revoked endpoint's next operation is refused.
    try std.testing.expect(!session.revocation.mayOperate(.revoked));
}

test "package vectors: downgrade and signer discipline via channel offering" {
    // test-vectors/package: a downgrade is refused. (Channel offering enforces the version floor.)
    try std.testing.expect(!packaging.channel.mayOffer(.{ .maturity = .stable, .version = 4 }, .stable, 4));
    try std.testing.expect(!packaging.channel.mayOffer(.{ .maturity = .stable, .version = 3 }, .stable, 4));
}

test "update vectors: interrupted-before-commit boots the prior version" {
    // test-vectors/update: an unconfirmed updated slot out of attempts falls back to current (prior).
    try std.testing.expectEqual(
        packaging.recovery.Slot.current,
        packaging.recovery.bootSlot(.{ .confirmed = false, .attempts_used = 2, .attempts_allowed = 2 }),
    );
    // A confirmed slot commits to the new version.
    try std.testing.expectEqual(
        packaging.recovery.Slot.updated,
        packaging.recovery.bootSlot(.{ .confirmed = true, .attempts_used = 1, .attempts_allowed = 2 }),
    );
}

test "crypto vectors: digest comparison is exact" {
    // test-vectors/crypto: digest-equal → equal; first/last-byte-differs → not equal.
    const base: emulator.image.Digest = [_]u8{0x00} ** 32;
    try std.testing.expect(emulator.image.mayBoot(base, base));
    var first = base;
    first[0] = 0x01;
    try std.testing.expect(!emulator.image.mayBoot(first, base));
    var last = base;
    last[31] = 0x01;
    try std.testing.expect(!emulator.image.mayBoot(last, base));
}
