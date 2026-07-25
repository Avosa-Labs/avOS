//! The applications thesis, as tests over ground truth: an agent works a real app,
//! the person watches it from the ledger, a consequential act is held and then runs
//! exactly once, and an unauthorized act is denied and just as visible.
//!
//! Every assertion here reads the same audit ledger the framework gated execution
//! against, never a string an agent supplied — so a green test is the live-watch demo
//! being honest. The four properties are the ones that separate an agent-native app
//! from simulation: an agent's real operation is recorded and watchable; an
//! unauthorized operation is denied, recorded, and shown; a consequential operation is
//! held and then applied once even if approved twice; and the person's own action runs
//! the identical domain code the agent's did.

const std = @import("std");
const core = @import("core");
const framework = @import("../framework/agent_app.zig");
const messages = @import("../messages/messages.zig");

const testing = std.testing;
const identity = core.identity;
const time = core.time;

const person: u128 = 0x5;
const assistant: u128 = 0xA;

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    ledger: core.audit.Ledger,
    store: messages.Store,
    app: messages.App,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) void {
        fixture.ids = .initDeterministic(99);
        fixture.manual = .init(.fromSeconds(1000));
        fixture.ledger = .init(gpa, &fixture.ids, fixture.manual.clock());
        fixture.store = messages.Store.init(gpa);
        fixture.app = messages.open(&fixture.store, &fixture.ledger);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.store.deinit();
        fixture.ledger.deinit();
    }

    fn agent(_: Fixture) framework.Actor {
        return .{ .kind = .agent, .principal = .{ .value = assistant } };
    }
    fn human(_: Fixture) framework.Actor {
        return .{ .kind = .human, .principal = .{ .value = person } };
    }
};

test "an agent works Messages and the person watches it from the ledger" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // The agent searches and drafts — safe operations it completes on its own.
    try testing.expect((try fixture.app.invoke(fixture.agent(), "message.search", "messages.read", true, 1)).ran());
    try testing.expect((try fixture.app.invoke(fixture.agent(), "message.draft", "messages.compose", true, 2)).ran());

    // The person's live view is derived from the ledger — not from anything the agent
    // said — and shows exactly what the agent did.
    const feed = try framework.feedForActor(&fixture.ledger, gpa, .{ .value = assistant });
    defer gpa.free(feed);
    try testing.expectEqual(@as(usize, 2), feed.len);
    try testing.expectEqualStrings("message.search", feed[0].operation);
    try testing.expectEqual(core.outcome.Outcome.succeeded, feed[1].outcome);
}

test "a consequential agent operation is held, then approved, and runs exactly once" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // The agent proposes a send: it is held, not run.
    const proposal = try fixture.app.invoke(fixture.agent(), "message.send", "messages.send", true, 7);
    try testing.expectEqual(framework.Outcome.held, proposal);
    try testing.expectEqual(@as(usize, 0), fixture.store.sent());

    // The person approves it — twice, as a double tap or a retry after a restart would.
    // The keyed effect applies once.
    _ = try fixture.app.approve(fixture.human(), "message.send", 7);
    _ = try fixture.app.approve(fixture.human(), "message.send", 7);
    try testing.expectEqual(@as(usize, 1), fixture.store.sent());
}

test "an unauthorized agent operation is denied, recorded, and visible in the feed" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // The agent presents the wrong capability for send — denied, fail-closed.
    const outcome = try fixture.app.invoke(fixture.agent(), "message.send", "messages.read", false, 3);
    switch (outcome) {
        .denied => {},
        else => return error.TestExpectedDenial,
    }
    // Nothing was sent, and the denial is in the ledger's denied feed for the person
    // to see — a refusal is as visible as an action.
    try testing.expectEqual(@as(usize, 0), fixture.store.sent());
    const denied = try framework.deniedFeed(&fixture.ledger, gpa);
    defer gpa.free(denied);
    try testing.expectEqual(@as(usize, 1), denied.len);
    try testing.expectEqualStrings("message.send", denied[0].operation);
}

test "the person's own send runs the identical domain path as the agent's" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A person performs the consequential op directly — same invoke, same domain.
    const outcome = try fixture.app.invoke(fixture.human(), "message.send", "messages.send", true, 9);
    try testing.expect(outcome.ran());
    try testing.expectEqual(@as(usize, 1), fixture.store.sent());
}
