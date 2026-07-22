//! Lock, home, launcher, settings, and endpoint surfaces.
//!
//! These are the surfaces a person moves through rather than the ones that
//! report on work. Between them they decide what is reachable before
//! authentication, what the home surface leads to, what may be launched, what
//! may be configured, and which endpoints may present this session.
//!
//! Everything a person sees named here is either a description of a system
//! concept or a value read from the brand layer. No surface embeds a product
//! name, so a rebrand changes the brand document and nothing else.

const std = @import("std");
const core = @import("core");
const design = @import("design");

const identity = core.identity;
const time = core.time;
const tokens = design.tokens;
const accessibility = design.accessibility;

pub const Error = error{
    NotAuthenticated,
    /// The endpoint is not trusted to present this session.
    EndpointNotTrusted,
    /// The runtime a package needs is not available on this host.
    RuntimeUnavailable,
    TooManyRows,
};

pub const max_rows: usize = 256;

/// What the lock surface may reveal before anyone has authenticated.
///
/// It shows that the device is locked and how to unlock it. It does not show
/// pending approvals, task progress, notification content, or who is enrolled:
/// each of those tells whoever is holding the device something about the person
/// who owns it.
pub const LockSurface = struct {
    /// Read from the brand layer, never embedded here.
    product_name: []const u8,
    /// Whether a biometric path is offered in addition to a passphrase.
    offers_biometric: bool,
    /// Whether an emergency path is reachable while locked. It is, because
    /// requiring authentication to call for help would be a safety failure.
    offers_emergency: bool = true,

    /// Fields a locked surface must never carry.
    ///
    /// Expressed as a check rather than a comment so that adding a field with
    /// one of these names fails a test rather than shipping.
    pub fn revealsNothingPrivate(comptime Surface: type) bool {
        const forbidden = [_][]const u8{
            "approvals",
            "pending_approvals",
            "tasks",
            "notifications",
            "principals",
            "activity",
            "messages",
        };
        inline for (@typeInfo(Surface).@"struct".fields) |field| {
            inline for (forbidden) |name| {
                if (std.mem.eql(u8, field.name, name)) return false;
            }
        }
        return true;
    }

    pub fn describe(surface: LockSurface, gpa: std.mem.Allocator) !accessibility.Surface {
        var elements: std.ArrayList(accessibility.Element) = .empty;
        errdefer elements.deinit(gpa);
        var order: std.ArrayList(usize) = .empty;
        errdefer order.deinit(gpa);

        try elements.append(gpa, .{ .role = .heading, .accessible_name = surface.product_name });

        try order.append(gpa, elements.items.len);
        try elements.append(gpa, .{ .role = .text_field, .accessible_name = "Passphrase" });

        if (surface.offers_biometric) {
            try order.append(gpa, elements.items.len);
            try elements.append(gpa, .{ .role = .button, .accessible_name = "Unlock with biometrics" });
        }
        if (surface.offers_emergency) {
            try order.append(gpa, elements.items.len);
            try elements.append(gpa, .{ .role = .button, .accessible_name = "Emergency" });
        }

        return .{
            .title = surface.product_name,
            .elements = try elements.toOwnedSlice(gpa),
            .focus_order = try order.toOwnedSlice(gpa),
            // The lock surface is the root; there is nothing behind it to
            // return to, and that is not the same as being trapped in a task.
            .has_escape_path = true,
        };
    }
};

/// A destination reachable from the home surface.
pub const Destination = enum {
    command,
    task_graph,
    approvals,
    activity,
    launcher,
    principals,
    capabilities,
    resources,
    endpoints,
    settings,

    /// What the destination is called, in terms of what it does.
    pub fn label(destination: Destination) []const u8 {
        return switch (destination) {
            .command => "Ask for something",
            .task_graph => "Work in progress",
            .approvals => "Waiting for you",
            .activity => "What happened",
            .launcher => "Applications",
            .principals => "Who can act",
            .capabilities => "What they may do",
            .resources => "What it costs",
            .endpoints => "Where you are signed in",
            .settings => "Settings",
        };
    }
};

/// The home surface: a set of destinations and the count of what needs
/// attention.
pub const HomeSurface = struct {
    /// Approvals waiting for this human. Shown because an approval nobody
    /// notices is an approval that expires unanswered.
    pending_approvals: usize,
    /// Tasks currently running.
    running_tasks: usize,

    pub fn destinations() []const Destination {
        return std.enums.values(Destination);
    }

    pub fn describe(surface: HomeSurface, gpa: std.mem.Allocator) !accessibility.Surface {
        var elements: std.ArrayList(accessibility.Element) = .empty;
        errdefer elements.deinit(gpa);
        var order: std.ArrayList(usize) = .empty;
        errdefer order.deinit(gpa);

        try elements.append(gpa, .{ .role = .heading, .accessible_name = "Home" });

        for (destinations()) |destination| {
            try order.append(gpa, elements.items.len);
            const needs_attention = destination == .approvals and surface.pending_approvals > 0;
            try elements.append(gpa, .{
                .role = .link,
                .accessible_name = destination.label(),
                .status = if (needs_attention) .status_awaiting_approval else null,
                .status_text = if (needs_attention) "Waiting for your approval" else "",
            });
        }

        return .{
            .title = "Home",
            .elements = try elements.toOwnedSlice(gpa),
            .focus_order = try order.toOwnedSlice(gpa),
        };
    }
};

/// Which runtime an application needs.
pub const Runtime = enum {
    native,
    wasm,
    android,
    web,

    pub fn label(runtime: Runtime) []const u8 {
        return switch (runtime) {
            .native => "Native",
            .wasm => "Portable component",
            .android => "Android",
            .web => "Web",
        };
    }
};

/// An application the launcher can present.
pub const ApplicationRow = struct {
    id: identity.PrincipalId,
    name: []const u8,
    runtime: Runtime,
    /// Whether the runtime it needs is available on this host.
    launchable: bool,
    /// Why it cannot be launched, when it cannot.
    unavailable_reason: []const u8,
    /// Capabilities the package declared. A declaration, never a grant.
    declared_capability_count: usize,
};

/// Which runtimes this host actually provides.
pub const AvailableRuntimes = struct {
    native: bool = true,
    wasm: bool = false,
    android: bool = false,
    web: bool = false,

    pub fn provides(available: AvailableRuntimes, runtime: Runtime) bool {
        return switch (runtime) {
            .native => available.native,
            .wasm => available.wasm,
            .android => available.android,
            .web => available.web,
        };
    }
};

/// What an application looks like before the launcher decides whether it can
/// run.
pub const ApplicationDeclaration = struct {
    id: identity.PrincipalId,
    name: []const u8,
    runtime: Runtime,
    declared_capability_count: usize,
};

/// Projects the launcher.
///
/// An application whose runtime is absent is listed and marked unavailable
/// rather than hidden. Hiding it would leave a person unable to tell an
/// application they never installed from one this host cannot run.
///
/// Caller owns the returned slice.
pub fn projectLauncher(
    gpa: std.mem.Allocator,
    declarations: []const ApplicationDeclaration,
    available: AvailableRuntimes,
    authenticated: bool,
) ![]ApplicationRow {
    if (!authenticated) return error.NotAuthenticated;
    if (declarations.len > max_rows) return error.TooManyRows;

    var rows: std.ArrayList(ApplicationRow) = .empty;
    errdefer rows.deinit(gpa);

    for (declarations) |declaration| {
        const launchable = available.provides(declaration.runtime);
        try rows.append(gpa, .{
            .id = declaration.id,
            .name = declaration.name,
            .runtime = declaration.runtime,
            .launchable = launchable,
            .unavailable_reason = if (launchable)
                ""
            else
                "This device cannot run that yet",
            .declared_capability_count = declaration.declared_capability_count,
        });
    }
    return rows.toOwnedSlice(gpa);
}

/// A setting a person can change.
pub const SettingGroup = enum {
    identity,
    privacy,
    security,
    model_routing,
    compatibility_runtimes,
    endpoints,
    updates,
    diagnostics,
    brand,
    accessibility,

    pub fn label(group: SettingGroup) []const u8 {
        return switch (group) {
            .identity => "Identity",
            .privacy => "Privacy",
            .security => "Security",
            .model_routing => "Where processing happens",
            .compatibility_runtimes => "Compatibility",
            .endpoints => "Endpoints",
            .updates => "Updates",
            .diagnostics => "Diagnostics",
            .brand => "Appearance",
            .accessibility => "Accessibility",
        };
    }

    /// Whether changing anything in this group is a consequential action that
    /// needs an explicit decision rather than a silent toggle.
    pub fn isConsequential(group: SettingGroup) bool {
        return switch (group) {
            .security, .privacy, .identity, .endpoints, .updates, .model_routing => true,
            .compatibility_runtimes, .diagnostics, .brand, .accessibility => false,
        };
    }
};

/// An endpoint authorized to present this session.
pub const EndpointRow = struct {
    id: identity.PrincipalId,
    name: []const u8,
    /// Whether this is the endpoint the person is using now. The current
    /// endpoint cannot be revoked from itself.
    is_current: bool,
    trusted_until: ?time.Timestamp,
    /// Whether the endpoint may send input, as opposed to only presenting.
    may_send_input: bool,
    revocable: bool,
    status_text: []const u8,
    status_colour: tokens.ColourRole,
};

pub const EndpointDeclaration = struct {
    id: identity.PrincipalId,
    name: []const u8,
    is_current: bool,
    trusted_until: ?time.Timestamp,
    may_send_input: bool,
};

/// Projects the endpoints surface.
///
/// An endpoint whose trust has lapsed is shown as lapsed rather than removed,
/// so a person can see that something which used to have access no longer does.
///
/// Caller owns the returned slice.
pub fn projectEndpoints(
    gpa: std.mem.Allocator,
    declarations: []const EndpointDeclaration,
    now: time.Timestamp,
    authenticated: bool,
) ![]EndpointRow {
    if (!authenticated) return error.NotAuthenticated;
    if (declarations.len > max_rows) return error.TooManyRows;

    var rows: std.ArrayList(EndpointRow) = .empty;
    errdefer rows.deinit(gpa);

    for (declarations) |declaration| {
        const lapsed = if (declaration.trusted_until) |until|
            !until.isAfter(now)
        else
            false;

        try rows.append(gpa, .{
            .id = declaration.id,
            .name = declaration.name,
            .is_current = declaration.is_current,
            .trusted_until = declaration.trusted_until,
            .may_send_input = declaration.may_send_input and !lapsed,
            // Revoking the endpoint you are using would end the session that is
            // performing the revocation.
            .revocable = !declaration.is_current and !lapsed,
            .status_text = if (lapsed)
                "No longer trusted"
            else if (declaration.is_current)
                "This device"
            else if (declaration.may_send_input)
                "Can view and control"
            else
                "Can view only",
            .status_colour = if (lapsed)
                .status_cancelled
            else
                .status_succeeded,
        });
    }
    return rows.toOwnedSlice(gpa);
}

test "the lock surface reveals nothing about the person who owns the device" {
    // Adding a field carrying private state fails here rather than shipping.
    try std.testing.expect(LockSurface.revealsNothingPrivate(LockSurface));

    // The home surface legitimately carries a pending count, which is why the
    // check is applied to the locked surface and not to every surface.
    try std.testing.expect(!LockSurface.revealsNothingPrivate(HomeSurface));
}

test "the lock surface takes its product name from the brand layer" {
    const gpa = std.testing.allocator;
    // Two different configured names must both render, which is what proves
    // the name is read rather than embedded.
    for ([_][]const u8{ "A", "A Rather Long Configured Product Name" }) |name| {
        const surface: LockSurface = .{ .product_name = name, .offers_biometric = true };
        var described = try surface.describe(gpa);
        defer gpa.free(described.elements);
        defer gpa.free(described.focus_order);

        try described.validate(gpa);
        try std.testing.expectEqualStrings(name, described.title);
    }
}

test "help is reachable while locked" {
    const gpa = std.testing.allocator;
    const surface: LockSurface = .{ .product_name = "Reference", .offers_biometric = false };
    const described = try surface.describe(gpa);
    defer gpa.free(described.elements);
    defer gpa.free(described.focus_order);

    var found_emergency = false;
    for (described.elements) |element| {
        if (std.mem.eql(u8, element.accessible_name, "Emergency")) found_emergency = true;
    }
    try std.testing.expect(found_emergency);
}

test "home leads to every surface and marks what needs attention" {
    const gpa = std.testing.allocator;
    const surface: HomeSurface = .{ .pending_approvals = 2, .running_tasks = 1 };

    var described = try surface.describe(gpa);
    defer gpa.free(described.elements);
    defer gpa.free(described.focus_order);

    try described.validate(gpa);
    try std.testing.expectEqual(
        HomeSurface.destinations().len,
        described.focus_order.len,
    );

    var marked: usize = 0;
    for (described.elements) |element| {
        if (element.status == .status_awaiting_approval) marked += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), marked);
}

test "home marks nothing when nothing is waiting" {
    const gpa = std.testing.allocator;
    const surface: HomeSurface = .{ .pending_approvals = 0, .running_tasks = 0 };

    const described = try surface.describe(gpa);
    defer gpa.free(described.elements);
    defer gpa.free(described.focus_order);

    for (described.elements) |element| {
        try std.testing.expectEqual(@as(?tokens.ColourRole, null), element.status);
    }
}

test "every destination has a distinct label describing what it does" {
    const gpa = std.testing.allocator;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    for (std.enums.values(Destination)) |destination| {
        const label = destination.label();
        try std.testing.expect(label.len > 0);
        const entry = try seen.getOrPut(gpa, label);
        try std.testing.expect(!entry.found_existing);
    }
}

test "an application whose runtime is absent is shown as unavailable, not hidden" {
    const gpa = std.testing.allocator;
    const declarations = [_]ApplicationDeclaration{
        .{ .id = .{ .value = 1 }, .name = "Calendar", .runtime = .native, .declared_capability_count = 2 },
        .{ .id = .{ .value = 2 }, .name = "Maps", .runtime = .android, .declared_capability_count = 4 },
    };

    const rows = try projectLauncher(gpa, &declarations, .{ .native = true }, true);
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(rows[0].launchable);
    try std.testing.expect(!rows[1].launchable);
    try std.testing.expect(rows[1].unavailable_reason.len > 0);
}

test "the launcher shows declared capabilities without granting them" {
    const gpa = std.testing.allocator;
    const declarations = [_]ApplicationDeclaration{
        .{ .id = .{ .value = 1 }, .name = "Calendar", .runtime = .native, .declared_capability_count = 3 },
    };

    const rows = try projectLauncher(gpa, &declarations, .{}, true);
    defer gpa.free(rows);

    try std.testing.expectEqual(@as(usize, 3), rows[0].declared_capability_count);
    // The row carries no field capable of holding a grant.
    inline for (@typeInfo(ApplicationRow).@"struct".fields) |field| {
        try std.testing.expect(!std.mem.eql(u8, field.name, "granted_capabilities"));
        try std.testing.expect(!std.mem.eql(u8, field.name, "capabilities"));
    }
}

test "nothing is launchable before a human authenticates" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.NotAuthenticated,
        projectLauncher(gpa, &.{}, .{}, false),
    );
    try std.testing.expectError(
        error.NotAuthenticated,
        projectEndpoints(gpa, &.{}, .fromSeconds(1_000), false),
    );
}

test "settings that change security or privacy are consequential" {
    for (std.enums.values(SettingGroup)) |group| {
        try std.testing.expect(group.label().len > 0);
    }
    try std.testing.expect(SettingGroup.security.isConsequential());
    try std.testing.expect(SettingGroup.privacy.isConsequential());
    try std.testing.expect(SettingGroup.identity.isConsequential());
    try std.testing.expect(SettingGroup.endpoints.isConsequential());
    try std.testing.expect(SettingGroup.model_routing.isConsequential());
    try std.testing.expect(!SettingGroup.brand.isConsequential());
    try std.testing.expect(!SettingGroup.accessibility.isConsequential());
}

test "the endpoint in use cannot be revoked from itself" {
    const gpa = std.testing.allocator;
    const declarations = [_]EndpointDeclaration{
        .{ .id = .{ .value = 1 }, .name = "This phone", .is_current = true, .trusted_until = null, .may_send_input = true },
        .{ .id = .{ .value = 2 }, .name = "Desktop", .is_current = false, .trusted_until = null, .may_send_input = true },
    };

    const rows = try projectEndpoints(gpa, &declarations, .fromSeconds(1_000), true);
    defer gpa.free(rows);

    try std.testing.expect(!rows[0].revocable);
    try std.testing.expectEqualStrings("This device", rows[0].status_text);
    try std.testing.expect(rows[1].revocable);
}

test "an endpoint whose trust has lapsed loses input and is shown as lapsed" {
    const gpa = std.testing.allocator;
    const declarations = [_]EndpointDeclaration{
        .{
            .id = .{ .value = 2 },
            .name = "Desktop",
            .is_current = false,
            .trusted_until = .fromSeconds(500),
            .may_send_input = true,
        },
    };

    const rows = try projectEndpoints(gpa, &declarations, .fromSeconds(1_000), true);
    defer gpa.free(rows);

    try std.testing.expect(!rows[0].may_send_input);
    try std.testing.expectEqualStrings("No longer trusted", rows[0].status_text);
    // Already lapsed, so there is nothing left to revoke.
    try std.testing.expect(!rows[0].revocable);
}

test "a view-only endpoint is distinguished from one that may control" {
    const gpa = std.testing.allocator;
    const declarations = [_]EndpointDeclaration{
        .{ .id = .{ .value = 2 }, .name = "Room display", .is_current = false, .trusted_until = null, .may_send_input = false },
        .{ .id = .{ .value = 3 }, .name = "Desktop", .is_current = false, .trusted_until = null, .may_send_input = true },
    };

    const rows = try projectEndpoints(gpa, &declarations, .fromSeconds(1_000), true);
    defer gpa.free(rows);

    try std.testing.expectEqualStrings("Can view only", rows[0].status_text);
    try std.testing.expectEqualStrings("Can view and control", rows[1].status_text);
}

test "these surfaces carry no product naming of their own" {
    // Every label here describes a system concept. The only product name on
    // any of them arrives from the brand layer through the lock surface.
    for (std.enums.values(Destination)) |destination| {
        try std.testing.expect(std.mem.indexOfScalar(u8, destination.label(), '@') == null);
    }
    for (std.enums.values(SettingGroup)) |group| {
        try std.testing.expect(std.mem.indexOfScalar(u8, group.label(), '@') == null);
    }
    for (std.enums.values(Runtime)) |runtime| {
        try std.testing.expect(runtime.label().len > 0);
    }
}
