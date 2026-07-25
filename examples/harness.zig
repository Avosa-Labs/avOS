//! The real platform, stood up for an example to run against.
//!
//! An example on this platform is not a script that narrates what an agent would do; it
//! is a program that drives the same machinery a shipped app drives — the capability
//! gate, the one shared domain, the audit ledger the live feed reads. For that to be
//! true the example needs the real thing to run against, not a mock of it. This module
//! is that real thing, in miniature: an identity source, a clock, and an append-only
//! audit ledger, exactly the ones the platform's own subsystems use, assembled so an
//! example and its tests can issue operations and then read back the ledger they wrote.
//!
//! What makes an example honest is that its result is read from this ledger rather than
//! reported by the code that ran. `feed` returns the recorded events; an example asserts
//! against those, so a passing example is proof the real path ran, not that a narration
//! matched. The same harness the tests use is the one a demonstration runs, so "the
//! demo" is the real program executing, watched through the same record that gated it.

const std = @import("std");
const core = @import("core");
const applications = @import("applications");

const identity = core.identity;
const audit = core.audit;
const time = core.time;

pub const framework = applications.framework;
pub const FeedItem = framework.FeedItem;

/// The running platform an example executes against: the identity source that mints
/// principals, the clock the ledger stamps events with, and the ledger itself.
///
/// Ownership: the world owns all three. `deinit` releases the ledger. Because the
/// ledger borrows the source and clock by pointer, the world is initialized in place —
/// `init(gpa, &world)` — so those pointers stay valid for the world's whole life.
pub const World = struct {
    gpa: std.mem.Allocator,
    ids: identity.Source,
    manual: time.ManualClock,
    ledger: audit.Ledger,

    /// Stands up the world in place. The seed makes principal ids deterministic, so an
    /// example's output is stable to read and to assert against.
    pub fn init(gpa: std.mem.Allocator, world: *World, seed: u64) void {
        world.* = .{
            .ids = .initDeterministic(seed),
            .manual = .init(.fromSeconds(1_000)),
            .gpa = gpa,
            .ledger = undefined,
        };
        world.ledger = .init(gpa, &world.ids, world.manual.clock());
    }

    pub fn deinit(world: *World) void {
        world.ledger.deinit();
        world.* = undefined;
    }

    /// A principal id for a role in the example. The number is the role's identity;
    /// keeping them small and explicit makes an example's ledger readable.
    pub fn principal(value: u128) identity.PrincipalId {
        return .{ .value = value };
    }

    /// Everything an actor did, read from the ledger and nothing else. This is the
    /// live feed an example asserts against, so the assertion is against the recorded
    /// ground truth rather than a claim the example made about itself. Caller owns the
    /// returned slice.
    pub fn feed(world: *World, actor: identity.PrincipalId) ![]FeedItem {
        return framework.feedForActor(&world.ledger, world.gpa, actor);
    }

    /// The denials in the ledger — the operations refused before they ran, which a
    /// person watching must see as plainly as the ones that succeeded. Caller owns the
    /// returned slice.
    pub fn denials(world: *World) ![]FeedItem {
        return framework.deniedFeed(&world.ledger, world.gpa);
    }
};

/// Whether a feed carries an event for an operation with a given outcome. Examples use
/// it to assert that a step reached the ledger the way it claims to have — that a send
/// is recorded succeeded, a denial recorded denied — rather than trusting a return
/// value alone.
pub fn feedHas(
    items: []const FeedItem,
    operation: []const u8,
    outcome: core.outcome.Outcome,
) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.operation, operation) and item.outcome == outcome) return true;
    }
    return false;
}

test "the world stands up a real ledger that records and reads back" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    World.init(gpa, &world, 1);
    defer world.deinit();

    const actor = World.principal(1);
    _ = try world.ledger.append(.{
        .actor = actor,
        .action = .tool_invoked,
        .outcome = .succeeded,
        .target_kind = "example.op",
    });

    const items = try world.feed(actor);
    defer gpa.free(items);
    try std.testing.expect(feedHas(items, "example.op", .succeeded));
}
