//! Attack: bypass a setting's sensitivity class by writing it directly.
//!
//! The platform's claim is that a setting's sensitivity class — decided in the registry, a property
//! of the setting — governs every write, whoever asks. The attack is to reach past the UI straight
//! to the policy store, as an agent, and change something the class forbids: a human_only setting
//! (the lock method, a safety limit) or a hold setting slipped through without the person. This
//! drives that attack against every class in the registry and asserts it fails: a human_only write
//! by an agent is refused outright and the value is unchanged, a hold write is held and never takes
//! effect, and the person — but only the person — can make the change. The class is the setting's,
//! not the caller's, so no capability an agent presents changes any of this.

const std = @import("std");
const core = @import("core");

const settings = core.policy.settings;

test "attack: an agent cannot write any human_only setting, however it proposes" {
    // Every human_only key in the registry: an agent's write is refused and the value is unchanged.
    for (settings.registry) |entry| {
        if (entry.class != .human_only) continue;
        var store = settings.Store.init();
        const before = store.get(entry.key).?;
        const outcome = store.propose(entry.key, entry.default, .agent);
        try std.testing.expectEqual(settings.Outcome.rejected_unauthorized, outcome);
        try std.testing.expect(std.meta.eql(store.get(entry.key).?, before)); // unchanged
    }
}

test "attack: an agent cannot slip a hold setting through without the person" {
    // Every hold key: an agent's write is held, not applied — the value does not change until the
    // person approves it elsewhere.
    for (settings.registry) |entry| {
        if (entry.class != .hold) continue;
        var store = settings.Store.init();
        const before = store.get(entry.key).?;
        const outcome = store.propose(entry.key, entry.default, .agent);
        try std.testing.expectEqual(settings.Outcome.held_for_approval, outcome);
        try std.testing.expect(std.meta.eql(store.get(entry.key).?, before)); // not applied yet
    }
}

test "the person is not blocked: a human writes what the class forbids an agent" {
    // The class binds agents, not the person. For a human_only key the person's write applies.
    const lock = settings.find("security.lock_method") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(settings.Class.human_only, lock.class);
    var store = settings.Store.init();
    try std.testing.expectEqual(settings.Outcome.applied, store.propose("security.lock_method", .{ .choice = "biometric" }, .human));
    try std.testing.expectEqualStrings("biometric", store.get("security.lock_method").?.choice);
}

test "the registry actually carries the classes this attack depends on" {
    // If the registry ever lost its human_only and hold keys, the tests above would pass vacuously.
    // Guard against that: both classes must be present for the attack to be a real one.
    var has_human_only = false;
    var has_hold = false;
    for (settings.registry) |entry| {
        if (entry.class == .human_only) has_human_only = true;
        if (entry.class == .hold) has_hold = true;
    }
    try std.testing.expect(has_human_only);
    try std.testing.expect(has_hold);
}
