//! The Personal Compute Instance and continuity between endpoints.
//!
//! A person's environment is not a device. It is an instance that exists while
//! every endpoint is offline, and endpoints are authenticated manifestations of
//! it rather than the place it lives. Moving between them changes which
//! endpoint is presenting; it does not change who the principal is, what work
//! is in flight, or what has already happened.
//!
//! The rule that governs everything here: a consequential action executes
//! exactly once across the whole instance. Continuity is where that is easiest
//! to get wrong — a task resumed on a second endpoint must not repeat the
//! external effect the first one already committed — so effects are recorded
//! against the instance and claimed before they run, never after.

const std = @import("std");
const core = @import("core");
const endpoint_model = @import("../endpoint/endpoint.zig");

const identity = core.identity;
const time = core.time;
const audit = core.audit;
const outcome_model = core.outcome;

pub const Error = error{
    /// The effect has already been claimed or performed.
    AlreadyPerformed,
    /// The effect reached an external system with an unknown result and must
    /// not be retried automatically.
    OutcomeUnknown,
    /// The endpoint may not do this.
    EndpointNotPermitted,
    /// No such transfer is in progress.
    UnknownTransfer,
    /// The instance holds no such effect record.
    UnknownEffect,
};

/// Which category of state a piece of instance state belongs to.
///
/// The categories differ in where they may go. Presentation state may be sent
/// to any endpoint that may present; secret state goes nowhere; durable
/// personal state synchronizes only to endpoints trusted to hold it. Treating
/// them alike is how a room display ends up holding a passphrase.
pub const StateCategory = enum {
    presentation,
    durable_personal,
    secret,
    application_private,
    agent_working,
    audit,

    /// Whether this category may be sent to an endpoint that only presents.
    pub fn mayReachPresentingEndpoint(category: StateCategory) bool {
        return switch (category) {
            .presentation => true,
            .durable_personal,
            .secret,
            .application_private,
            .agent_working,
            .audit,
            => false,
        };
    }

    /// Whether this category may leave the instance at all.
    pub fn maySynchronize(category: StateCategory) bool {
        return category != .secret;
    }
};

/// An external effect the instance may perform exactly once.
///
/// Identified by a key the caller derives from what the effect *is*, not from
/// when or where it runs, so the same intended effect produces the same key on
/// any endpoint.
pub const Effect = struct {
    key: u128,
    /// What performing it does, for the ledger and for a person reading it.
    description: []const u8,
    state: State,
    /// The endpoint that claimed it.
    claimed_by: identity.PrincipalId,
    claimed_at: time.Timestamp,

    pub const State = enum {
        /// Claimed by an endpoint, not yet known to have run.
        claimed,
        /// Known to have taken effect.
        performed,
        /// Reached an external system with an unknown result.
        outcome_unknown,
        /// Known not to have taken effect; may be claimed again.
        failed,

        pub fn permitsReclaim(state: State) bool {
            return state == .failed;
        }
    };
};

/// A transfer of the presenting endpoint.
pub const Transfer = struct {
    from: identity.PrincipalId,
    to: identity.PrincipalId,
    started_at: time.Timestamp,
    completed: bool,
};

/// The persistent personal environment.
///
/// Ownership: the instance owns its effect records and the descriptions it
/// copies. `deinit` releases them.
pub const Instance = struct {
    gpa: std.mem.Allocator,
    clock: time.Clock,
    /// The human whose environment this is. Unchanged by any transfer.
    human: identity.PrincipalId,
    endpoints: *endpoint_model.Registry,
    ledger: *audit.Ledger,
    /// The endpoint currently presenting, if any.
    presenting: identity.PrincipalId = .none,
    effects: std.AutoHashMapUnmanaged(u128, Effect) = .empty,
    owned_text: std.ArrayList([]const u8) = .empty,
    transfer: ?Transfer = null,

    pub fn init(
        gpa: std.mem.Allocator,
        clock: time.Clock,
        human: identity.PrincipalId,
        endpoints: *endpoint_model.Registry,
        ledger: *audit.Ledger,
    ) Instance {
        return .{
            .gpa = gpa,
            .clock = clock,
            .human = human,
            .endpoints = endpoints,
            .ledger = ledger,
        };
    }

    pub fn deinit(instance: *Instance) void {
        for (instance.owned_text.items) |text| instance.gpa.free(text);
        instance.owned_text.deinit(instance.gpa);
        instance.effects.deinit(instance.gpa);
        instance.* = undefined;
    }

    /// Claims an external effect before performing it.
    ///
    /// Claiming first is what makes exactly-once possible. An effect recorded
    /// only after it succeeded would be repeated by any endpoint that resumed
    /// the task between the effect happening and the record being written.
    pub fn claimEffect(
        instance: *Instance,
        key: u128,
        description: []const u8,
        claiming_endpoint: identity.PrincipalId,
    ) !void {
        _ = instance.endpoints.authorize(claiming_endpoint, instance.human, .input) catch
            return error.EndpointNotPermitted;

        if (instance.effects.get(key)) |existing| {
            switch (existing.state) {
                .claimed, .performed => return error.AlreadyPerformed,
                // An unknown result must not be retried automatically: the
                // effect may have happened, and repeating it would duplicate it.
                .outcome_unknown => return error.OutcomeUnknown,
                .failed => {},
            }
        }

        const owned = try instance.gpa.dupe(u8, description);
        errdefer instance.gpa.free(owned);
        try instance.owned_text.append(instance.gpa, owned);

        try instance.effects.put(instance.gpa, key, .{
            .key = key,
            .description = owned,
            .state = .claimed,
            .claimed_by = claiming_endpoint,
            .claimed_at = instance.clock.wall(),
        });

        _ = try instance.ledger.append(.{
            .actor = claiming_endpoint,
            .on_behalf_of = instance.human,
            .action = .capability_used,
            .outcome = .succeeded,
            .target_kind = "effect",
        });
    }

    /// Records what became of a claimed effect.
    pub fn settleEffect(
        instance: *Instance,
        key: u128,
        state: Effect.State,
    ) Error!void {
        const entry = instance.effects.getPtr(key) orelse return error.UnknownEffect;
        entry.state = state;
    }

    pub fn effectState(instance: Instance, key: u128) ?Effect.State {
        const entry = instance.effects.get(key) orelse return null;
        return entry.state;
    }

    /// Begins presenting on an endpoint.
    pub fn present(instance: *Instance, on: identity.PrincipalId) !void {
        _ = instance.endpoints.authorize(on, instance.human, .present) catch
            return error.EndpointNotPermitted;
        instance.presenting = on;

        _ = try instance.ledger.append(.{
            .actor = on,
            .on_behalf_of = instance.human,
            .action = .endpoint_connected,
            .outcome = .succeeded,
        });
    }

    /// Moves presentation to another endpoint.
    ///
    /// The principal does not change. Work in flight is untouched, and every
    /// effect already claimed stays claimed, which is what stops the second
    /// endpoint repeating it.
    pub fn transferTo(
        instance: *Instance,
        destination: identity.PrincipalId,
    ) !void {
        _ = instance.endpoints.authorize(destination, instance.human, .present) catch
            return error.EndpointNotPermitted;

        const origin = instance.presenting;
        instance.transfer = .{
            .from = origin,
            .to = destination,
            .started_at = instance.clock.wall(),
            .completed = false,
        };

        instance.presenting = destination;
        instance.transfer.?.completed = true;

        // Both endpoints are named, so the ledger can answer which device the
        // work moved between.
        _ = try instance.ledger.append(.{
            .actor = origin,
            .on_behalf_of = instance.human,
            .action = .endpoint_revoked,
            .outcome = .succeeded,
            .target_kind = "presentation",
        });
        _ = try instance.ledger.append(.{
            .actor = destination,
            .on_behalf_of = instance.human,
            .action = .endpoint_connected,
            .outcome = .succeeded,
            .target_kind = "presentation",
        });
    }

    /// Whether a category of state may be sent to a particular endpoint.
    pub fn maySynchronize(
        instance: Instance,
        category: StateCategory,
        to: identity.PrincipalId,
    ) bool {
        if (!category.maySynchronize()) return false;
        const record = instance.endpoints.lookup(to) orelse return false;
        if (!record.isTrusted(instance.clock.wall())) return false;

        if (category.mayReachPresentingEndpoint()) return record.permissions.may_present;
        // Anything beyond presentation state requires an endpoint the human
        // acts through, not merely one that displays.
        return record.permissions.may_send_input;
    }

    pub fn effectCount(instance: Instance) usize {
        return instance.effects.count();
    }
};

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    endpoints: endpoint_model.Registry,
    ledger: audit.Ledger,
    instance: Instance,
    human: identity.PrincipalId,
    phone: identity.PrincipalId,
    desktop: identity.PrincipalId,
    display: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        fixture.* = .{
            .ids = .initDeterministic(5150),
            .manual = .init(.fromSeconds(1_000)),
            .endpoints = undefined,
            .ledger = undefined,
            .instance = undefined,
            .human = .{ .value = 1 },
            .phone = .none,
            .desktop = .none,
            .display = .none,
        };
        const clock = fixture.manual.clock();
        fixture.endpoints = .init(gpa, &fixture.ids, clock);
        fixture.ledger = .init(gpa, &fixture.ids, clock);
        fixture.instance = .init(gpa, clock, fixture.human, &fixture.endpoints, &fixture.ledger);

        fixture.phone = try fixture.endpoints.enrol(.{
            .human = fixture.human,
            .name = "Phone",
            .permissions = .full,
        });
        fixture.desktop = try fixture.endpoints.enrol(.{
            .human = fixture.human,
            .name = "Desktop",
            .permissions = .full,
        });
        fixture.display = try fixture.endpoints.enrol(.{
            .human = fixture.human,
            .name = "Room display",
            .permissions = .present_only,
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.instance.deinit();
        fixture.ledger.deinit();
        fixture.endpoints.deinit();
    }
};

test "a task continues on a second endpoint without changing the principal" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    const human_before = fixture.instance.human;

    try fixture.instance.transferTo(fixture.desktop);

    try std.testing.expect(fixture.instance.presenting.eql(fixture.desktop));
    try std.testing.expect(fixture.instance.human.eql(human_before));
    try std.testing.expect(fixture.instance.transfer.?.completed);
}

test "an effect claimed on one endpoint cannot be repeated on another" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    const key: u128 = 0xc0ffee;

    try fixture.instance.claimEffect(key, "send a confirmation to the venue", fixture.phone);
    try fixture.instance.settleEffect(key, .performed);

    try fixture.instance.transferTo(fixture.desktop);

    // The resumed task tries the same effect from the second endpoint.
    try std.testing.expectError(
        error.AlreadyPerformed,
        fixture.instance.claimEffect(key, "send a confirmation to the venue", fixture.desktop),
    );
    try std.testing.expectEqual(@as(usize, 1), fixture.instance.effectCount());
}

test "an effect claimed but not yet settled still cannot be repeated" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    const key: u128 = 0xbeef;

    // Claimed and in flight. A second endpoint resuming the task must not
    // start it again, because whether it ran is not yet known.
    try fixture.instance.claimEffect(key, "pay the deposit", fixture.phone);
    try std.testing.expectError(
        error.AlreadyPerformed,
        fixture.instance.claimEffect(key, "pay the deposit", fixture.desktop),
    );
}

test "an effect with an unknown result is never retried automatically" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    const key: u128 = 0xfeed;

    try fixture.instance.claimEffect(key, "transfer the deposit", fixture.phone);
    try fixture.instance.settleEffect(key, .outcome_unknown);

    // It may have happened. Repeating it would duplicate it.
    try std.testing.expectError(
        error.OutcomeUnknown,
        fixture.instance.claimEffect(key, "transfer the deposit", fixture.desktop),
    );
    try std.testing.expect(!outcome_model.Outcome.outcome_unknown.hadNoEffect());
}

test "an effect known to have failed may be claimed again" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    const key: u128 = 0xdead;

    try fixture.instance.claimEffect(key, "send a confirmation", fixture.phone);
    try fixture.instance.settleEffect(key, .failed);

    // Known not to have happened, so retrying duplicates nothing.
    try fixture.instance.claimEffect(key, "send a confirmation", fixture.desktop);
    try std.testing.expectEqual(Effect.State.claimed, fixture.instance.effectState(key).?);
}

test "a presenting-only endpoint cannot claim an effect" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.display);

    try std.testing.expectError(
        error.EndpointNotPermitted,
        fixture.instance.claimEffect(0xaaa, "send a confirmation", fixture.display),
    );
}

test "a revoked endpoint loses access mid-session" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.desktop);
    try fixture.instance.claimEffect(0x111, "first effect", fixture.desktop);

    try fixture.endpoints.revoke(fixture.desktop);

    try std.testing.expectError(
        error.EndpointNotPermitted,
        fixture.instance.claimEffect(0x222, "second effect", fixture.desktop),
    );
    try std.testing.expectError(
        error.EndpointNotPermitted,
        fixture.instance.transferTo(fixture.desktop),
    );
}

test "the audit identifies both endpoint principals across a transfer" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    try fixture.instance.transferTo(fixture.desktop);

    const from_phone = try fixture.ledger.eventsForActor(gpa, fixture.phone);
    defer gpa.free(from_phone);
    const from_desktop = try fixture.ledger.eventsForActor(gpa, fixture.desktop);
    defer gpa.free(from_desktop);

    try std.testing.expect(from_phone.len > 0);
    try std.testing.expect(from_desktop.len > 0);
    try std.testing.expect(fixture.ledger.verifySequence());
}

test "secret state never leaves the instance" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try std.testing.expect(!StateCategory.secret.maySynchronize());
    for ([_]identity.PrincipalId{ fixture.phone, fixture.desktop, fixture.display }) |target| {
        try std.testing.expect(!fixture.instance.maySynchronize(.secret, target));
    }
}

test "a presenting endpoint receives presentation state and nothing more" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try std.testing.expect(fixture.instance.maySynchronize(.presentation, fixture.display));

    // A room display holding durable personal state is exactly what the
    // categories exist to prevent.
    const beyond = [_]StateCategory{
        .durable_personal,
        .application_private,
        .agent_working,
        .audit,
    };
    for (beyond) |category| {
        try std.testing.expect(!fixture.instance.maySynchronize(category, fixture.display));
        try std.testing.expect(fixture.instance.maySynchronize(category, fixture.desktop));
    }
}

test "a revoked endpoint receives nothing at all" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.endpoints.revoke(fixture.desktop);

    for (std.enums.values(StateCategory)) |category| {
        try std.testing.expect(!fixture.instance.maySynchronize(category, fixture.desktop));
    }
}

test "the instance exists independently of any endpoint presenting it" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    try fixture.instance.claimEffect(0x999, "an effect", fixture.phone);

    // Every endpoint goes away. The instance and its record of what has
    // happened do not.
    try fixture.endpoints.revoke(fixture.phone);
    try fixture.endpoints.revoke(fixture.desktop);
    try fixture.endpoints.revoke(fixture.display);

    try std.testing.expect(fixture.instance.human.eql(fixture.human));
    try std.testing.expectEqual(@as(usize, 1), fixture.instance.effectCount());
    try std.testing.expectEqual(Effect.State.claimed, fixture.instance.effectState(0x999).?);
}

test "an effect key identifies what the effect is, not when it ran" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    try fixture.instance.present(fixture.phone);
    const key: u128 = 0x5150;
    try fixture.instance.claimEffect(key, "send a confirmation", fixture.phone);

    // Time passing does not make the same effect a different one.
    fixture.manual.advance(.fromSeconds(86_400));
    try std.testing.expectError(
        error.AlreadyPerformed,
        fixture.instance.claimEffect(key, "send a confirmation", fixture.phone),
    );
}
