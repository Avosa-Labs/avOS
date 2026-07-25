//! Deciding whether a call from web content may cross into a host capability, so a
//! page can use only the authority explicitly bridged to it and its untrusted content
//! can never drive a host effect on its own.
//!
//! A web page hosted here may need to do things only the host can do — take a photo,
//! read a granted file — and the bridge is the one doorway between the page's world and
//! the host's. Everything about that doorway is closed by default. A page may call only
//! the host functions explicitly exposed to it; a name it was not bridged is not
//! dispatched, so a page cannot reach a host capability by guessing at it. And the
//! content of a page is untrusted — scripts, and anything they pulled from the network —
//! so a consequential call the bridge does permit is not simply executed on the page's
//! say-so; it is surfaced for the host's approval, because a page driven by injected
//! content must not be able to spend or send by itself. The bridge exposes a small,
//! named surface and treats every consequential crossing as a request, not a command.
//!
//! This module dispatches nothing. It decides whether a bridged call may proceed, and
//! whether it needs host approval, from the exposed surface and the call's effect, as a
//! pure function.

const std = @import("std");
const core = @import("core");
const host_bridge = @import("host_bridge");

const capability = core.capability;
const identity = core.identity;

/// What a bridged host function does, which sets whether a page may invoke it on its
/// own.
pub const Effect = enum {
    /// Reads state the page was granted; changes nothing.
    read,
    /// A local, reversible change within the page's grant.
    local,
    /// A consequential effect: sending, publishing, spending. Never runs on the page's
    /// say-so alone.
    consequential,

    fn needsApproval(effect: Effect) bool {
        return effect == .consequential;
    }

    /// The capability operation a call with this effect requires, so the exposure
    /// decision and the capability check agree on what authority a call needs.
    fn operation(effect: Effect) capability.Operation {
        return switch (effect) {
            .read => .read,
            .local, .consequential => .write,
        };
    }
};

/// A host function exposed to a page across the bridge.
pub const Exposed = struct {
    name: []const u8,
    effect: Effect,
    /// The host resource kind the function acts on, matched against the page's
    /// capability at the boundary. Empty on functions declared before capability
    /// binding, which the exposure-only `call` still serves.
    resource_kind: []const u8 = "",
};

/// Why a bridged call was refused.
pub const Refusal = enum {
    /// The page called a name that was not exposed to it. Not dispatched.
    not_exposed,
    /// The name is exposed but the page holds no capability authorizing it.
    unauthorized,
};

/// The outcome of a bridged call.
pub const Decision = union(enum) {
    /// The call may run directly.
    invoke,
    /// The call is permitted but must be surfaced for host approval first, because it
    /// is consequential and the page's content is untrusted.
    require_approval,
    /// The call is refused.
    refuse: Refusal,

    pub fn permitted(decision: Decision) bool {
        return decision == .invoke or decision == .require_approval;
    }
};

/// The bridge surface exposed to one page: the closed set of callable host functions.
pub const Surface = struct {
    exposed: []const Exposed,

    fn find(surface: Surface, name: []const u8) ?Exposed {
        for (surface.exposed) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }

    /// Decides whether a page's call to `name` may cross the bridge.
    ///
    /// The name must be one exposed to this page, or the call is refused rather than
    /// dispatched — a page cannot reach a host function it was not bridged. An exposed
    /// read or local call runs directly; an exposed consequential call is returned as
    /// requiring approval, because the page's content is untrusted and a consequential
    /// effect must not run on its say-so alone.
    pub fn call(surface: Surface, name: []const u8) Decision {
        const function = surface.find(name) orelse return .{ .refuse = .not_exposed };
        if (function.effect.needsApproval()) return .require_approval;
        return .invoke;
    }

    /// Decides a page's call against both the exposed surface and the capability the
    /// page holds, so an exposed name is not enough — the page must also hold
    /// authority for the resource it acts on.
    ///
    /// Exposure is checked first: a name never bridged is refused without consulting
    /// any authority. Then the call crosses the shared host-capability bridge under
    /// the page's handle; a page that holds no matching capability is refused as
    /// unauthorized, closing the gap where an exposed function could be driven by
    /// injected content with no grant behind it. Only a call that is both exposed and
    /// authorized proceeds — directly, or via approval when it is consequential.
    pub fn authorize(
        surface: Surface,
        name: []const u8,
        bridge: *host_bridge.Bridge,
        holder: identity.PrincipalId,
        handle: capability.Handle,
    ) Decision {
        const function = surface.find(name) orelse return .{ .refuse = .not_exposed };
        const crossing = bridge.cross(.{
            .holder = holder,
            .handle = handle,
            .operation = function.effect.operation(),
            .resource_kind = function.resource_kind,
        });
        if (!crossing.allowed()) return .{ .refuse = .unauthorized };
        if (function.effect.needsApproval()) return .require_approval;
        return .invoke;
    }
};

const exposed = [_]Exposed{
    .{ .name = "readGrantedFile", .effect = .read },
    .{ .name = "saveDraft", .effect = .local },
    .{ .name = "sendMessage", .effect = .consequential },
};

const sample_surface: Surface = .{ .exposed = &exposed };

test "an exposed read call invokes directly" {
    try std.testing.expectEqual(Decision.invoke, sample_surface.call("readGrantedFile"));
}

test "an exposed local call invokes directly" {
    try std.testing.expectEqual(Decision.invoke, sample_surface.call("saveDraft"));
}

test "an exposed consequential call requires approval" {
    try std.testing.expectEqual(Decision.require_approval, sample_surface.call("sendMessage"));
}

test "a call to an unexposed name is refused, not dispatched" {
    try std.testing.expectEqual(Decision{ .refuse = .not_exposed }, sample_surface.call("deleteEverything"));
    // A near miss is still not exposed.
    try std.testing.expectEqual(Decision{ .refuse = .not_exposed }, sample_surface.call("readgrantedfile"));
}

test "an empty surface exposes nothing" {
    const empty: Surface = .{ .exposed = &.{} };
    try std.testing.expectEqual(Decision{ .refuse = .not_exposed }, empty.call("readGrantedFile"));
}

test "no consequential call ever invokes without approval, swept" {
    // The untrusted-content property: any consequential exposed function returns
    // require_approval, never a bare invoke.
    for (exposed) |function| {
        const decision = sample_surface.call(function.name);
        if (function.effect == .consequential) {
            try std.testing.expectEqual(Decision.require_approval, decision);
        } else {
            try std.testing.expectEqual(Decision.invoke, decision);
        }
    }
}

test "only exposed names are ever permitted, swept" {
    const names = [_][]const u8{ "readGrantedFile", "saveDraft", "sendMessage", "unknown", "" };
    for (names) |name| {
        var is_exposed = false;
        for (exposed) |function| {
            if (std.mem.eql(u8, function.name, name)) is_exposed = true;
        }
        try std.testing.expectEqual(is_exposed, sample_surface.call(name).permitted());
    }
}

// --- Capability-checked crossing ---

const time = core.time;
const principal_model = core.principal;

const capability_exposed = [_]Exposed{
    .{ .name = "readGrantedFile", .effect = .read, .resource_kind = "files" },
    .{ .name = "sendMessage", .effect = .consequential, .resource_kind = "messaging" },
};
const capability_surface: Surface = .{ .exposed = &capability_exposed };

const CapFixture = struct {
    ids: identity.Source,
    manual: time.ManualClock,
    registry: principal_model.Registry,
    store: capability.Store,
    operator: identity.PrincipalId,
    page: identity.PrincipalId,

    fn init(gpa: std.mem.Allocator, fixture: *CapFixture) !void {
        fixture.* = .{
            .ids = .initDeterministic(11),
            .manual = .init(.fromSeconds(1_000)),
            .registry = undefined,
            .store = undefined,
            .operator = .none,
            .page = .none,
        };
        fixture.registry = .init(gpa, &fixture.ids, fixture.manual.clock());
        fixture.store = .init(gpa, &fixture.ids, fixture.manual.clock(), &fixture.registry);
        fixture.operator = try fixture.registry.enroll(.{ .kind = .human, .display_name = "operator", .policy_domain = "local" });
        fixture.page = try fixture.registry.enroll(.{ .kind = .agent, .display_name = "page", .policy_domain = "local", .expires_at = .fromSeconds(100_000), .issuer = fixture.operator });
    }

    fn deinit(fixture: *CapFixture) void {
        fixture.store.deinit();
        fixture.registry.deinit();
    }

    fn grant(fixture: *CapFixture, kind: []const u8, operation: capability.Operation) !capability.Handle {
        var operations: capability.OperationSet = .initEmpty();
        operations.insert(operation);
        return fixture.store.issue(.{
            .issuer = fixture.operator,
            .holder = fixture.page,
            .resource = .{ .kind = kind },
            .operations = operations,
        });
    }
};

test "an exposed call the page holds no capability for is refused as unauthorized" {
    const gpa = std.testing.allocator;
    var fixture: CapFixture = undefined;
    try CapFixture.init(gpa, &fixture);
    defer fixture.deinit();

    // A capability for a different resource than the call names.
    const handle = try fixture.grant("calendar", .read);
    var bridge = host_bridge.Bridge.init(&fixture.store);
    const decision = capability_surface.authorize("readGrantedFile", &bridge, fixture.page, handle);
    try std.testing.expectEqual(Decision{ .refuse = .unauthorized }, decision);
}

test "an exposed call the page holds the capability for proceeds" {
    const gpa = std.testing.allocator;
    var fixture: CapFixture = undefined;
    try CapFixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grant("files", .read);
    var bridge = host_bridge.Bridge.init(&fixture.store);
    const decision = capability_surface.authorize("readGrantedFile", &bridge, fixture.page, handle);
    try std.testing.expectEqual(Decision.invoke, decision);
}

test "a consequential authorized call still requires approval" {
    const gpa = std.testing.allocator;
    var fixture: CapFixture = undefined;
    try CapFixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grant("messaging", .write);
    var bridge = host_bridge.Bridge.init(&fixture.store);
    const decision = capability_surface.authorize("sendMessage", &bridge, fixture.page, handle);
    try std.testing.expectEqual(Decision.require_approval, decision);
}

test "an unexposed name is refused before any capability is consulted" {
    const gpa = std.testing.allocator;
    var fixture: CapFixture = undefined;
    try CapFixture.init(gpa, &fixture);
    defer fixture.deinit();

    const handle = try fixture.grant("files", .read);
    var bridge = host_bridge.Bridge.init(&fixture.store);
    const decision = capability_surface.authorize("deleteEverything", &bridge, fixture.page, handle);
    try std.testing.expectEqual(Decision{ .refuse = .not_exposed }, decision);
    // The capability was never consulted for an unexposed name.
    try std.testing.expectEqual(@as(u64, 0), bridge.crossings);
}
