//! Posting a notification from an Android application, gated by the capability the
//! application holds, so an application cannot reach the person's notification
//! surface unless it was granted the authority to.
//!
//! A notification is an interruption: it reaches the person directly, and an
//! application that could post one freely could spam, phish, or nag without limit.
//! Android treats notifications as a permission for exactly this reason, and on this
//! device that permission is a capability. So a post does not go straight to the
//! surface — it crosses the host capability bridge first, presenting the capability
//! the application holds for the notification resource, and only a crossing the
//! bridge authorizes is admitted. An application without the capability is refused at
//! the boundary, before anything reaches the person. The content is carried through,
//! not interpreted; whether it may be shown is the only question this seam answers.
//!
//! It authorizes a post and hands the admitted content on; it renders no
//! notification. Drawing it on the person's surface is the shell's, on content this
//! seam has confirmed the application was permitted to send.

const std = @import("std");
const core = @import("core");
const host_bridge = @import("host_bridge");

const capability = core.capability;
const identity = core.identity;

/// The resource kind a notification post is authorized against.
pub const resource_kind = "notification";

/// A notification an application wants to post.
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
    /// Whether the notification interrupts the person now or waits quietly. A
    /// high-priority post is more consequential, but the authority is the same
    /// capability; priority is content, not permission.
    high_priority: bool = false,
};

/// Why a post was refused.
pub const Refusal = enum {
    /// The application holds no capability to post notifications.
    unauthorized,
    /// The title and body together exceed what the surface will carry.
    too_large,
};

/// The result of trying to post.
pub const Outcome = union(enum) {
    /// The post is authorized; this content may be shown.
    posted: Notification,
    /// The post is refused.
    refused: Refusal,

    pub fn shown(outcome: Outcome) bool {
        return outcome == .posted;
    }
};

/// The largest a title and body may be together, so an application cannot flood the
/// surface with one enormous notification.
pub const max_content_bytes: usize = 4096;

/// Posts a notification on an application's behalf, if the application holds the
/// capability to.
///
/// The crossing is decided first: the application presents its notification
/// capability, and the bridge authorizes it against what the application actually
/// holds. Only then is the content checked and handed on. An unauthorized
/// application is refused at the boundary — nothing about the notification reaches
/// the person, not even a rejected attempt they would see.
pub fn post(
    bridge: *host_bridge.Bridge,
    holder: identity.PrincipalId,
    handle: capability.Handle,
    notification: Notification,
) Outcome {
    const decision = bridge.cross(.{
        .holder = holder,
        .handle = handle,
        .operation = .write,
        .resource_kind = resource_kind,
    });
    if (!decision.allowed()) return .{ .refused = .unauthorized };

    if (notification.title.len + notification.body.len > max_content_bytes) {
        return .{ .refused = .too_large };
    }
    return .{ .posted = notification };
}

// --- Tests ---

const testing = std.testing;
const time = core.time;
const principal_model = core.principal;

const Fixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal_model.Registry,
    store: capability.Store,
    operator: identity.PrincipalId,
    app: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture) !void {
        fixture.* = .{
            .ids = .initDeterministic(7),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .operator = .none,
            .app = .none,
        };
        fixture.registry = .init(gpa, &fixture.ids, fixture.manual.clock());
        fixture.store = .init(gpa, &fixture.ids, fixture.manual.clock(), &fixture.registry);
        fixture.operator = try fixture.registry.enroll(.{ .kind = .human, .display_name = "operator", .policy_domain = "local" });
        fixture.app = try fixture.registry.enroll(.{ .kind = .agent, .display_name = "app", .policy_domain = "local", .expires_at = .fromSeconds(100_000), .issuer = fixture.operator });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    fn grantNotify(fixture: *Fixture) !capability.Handle {
        var operations: capability.OperationSet = .initEmpty();
        operations.insert(.write);
        return fixture.store.issue(.{
            .issuer = fixture.operator,
            .holder = fixture.app,
            .resource = .{ .kind = resource_kind },
            .operations = operations,
        });
    }
};

test "an application holding the capability posts a notification" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grantNotify();
    var bridge = host_bridge.Bridge.init(&fixture.store);
    const outcome = post(&bridge, fixture.app, handle, .{ .title = "Ready", .body = "Your ride is here" });
    try testing.expect(outcome.shown());
}

test "an application without the capability is refused at the boundary" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A capability for a different resource, not notifications.
    var operations: capability.OperationSet = .initEmpty();
    operations.insert(.write);
    const handle = try fixture.store.issue(.{
        .issuer = fixture.operator,
        .holder = fixture.app,
        .resource = .{ .kind = "calendar" },
        .operations = operations,
    });
    var bridge = host_bridge.Bridge.init(&fixture.store);
    const outcome = post(&bridge, fixture.app, handle, .{ .title = "Ready", .body = "x" });
    try testing.expectEqual(Refusal.unauthorized, outcome.refused);
    try testing.expectEqual(@as(u64, 1), bridge.denials);
}

test "an over-large notification is refused even with the capability" {
    const gpa = testing.allocator;
    var fixture: Fixture = undefined;
    try Fixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grantNotify();
    var bridge = host_bridge.Bridge.init(&fixture.store);
    const big: [max_content_bytes]u8 = @splat('x');
    const outcome = post(&bridge, fixture.app, handle, .{ .title = "t", .body = &big });
    try testing.expectEqual(Refusal.too_large, outcome.refused);
}
