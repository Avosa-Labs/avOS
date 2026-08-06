//! Deriving an agent's signed manifest from the authority envelope a person approved.
//!
//! The provisioning decision works in coarse axes — may the agent hold consequential authority, under
//! what approval floor, may its data leave the device, how deep may it delegate, what may it spend. A
//! manifest is concrete: named capabilities each carrying the approval class its operations run under, the
//! namespaces the agent reaches, its budgets, its delegation policy, its data class. The missing middle is
//! a per-role capability catalog — the account authorizes a class of authority, the catalog names the
//! concrete capabilities that class covers, and every entry is clamped back down to the envelope so the
//! manifest never grants more than the envelope allowed. Deriving is deny-by-default at the source: only
//! cataloged capabilities appear, and a consequential capability the envelope does not permit is dropped
//! rather than issued.
//!
//! This module derives; it approves nothing. The envelope reaching it is already bounded by the account
//! policy (the provisioning decision refused anything beyond it), so derivation is a pure, total mapping
//! from an approved envelope to the manifest that expresses it.

const std = @import("std");
const core = @import("core");
const provisioning = @import("provisioning.zig");
const account = @import("../account/creation.zig");

const manifest = core.trust.manifest;
const identity = core.identity;
const time = core.time;

pub const Error = error{UnknownRole} || std.mem.Allocator.Error;

/// The concrete authority surface for one role: the capabilities it may request and the namespaces it may
/// reach. These are templates — the envelope clamps each entry when the manifest is derived. The strings
/// are static, so a derived manifest borrows them for its whole lifetime without any copy.
pub const RoleCatalog = struct {
    capabilities: []const manifest.CapabilityRequest,
    namespaces: []const manifest.NamespaceGrant,
};

/// The per-role catalog. Every default agent role, and any role a person adds, names its authority surface
/// here in one place, so the concrete capabilities can be audited against the coarse envelope that bounds
/// them. A read/propose capability (silent/notify) is authority a conservative agent always holds; a
/// consequential one (hold/human_only) is authority only an envelope that permits it receives.
pub const catalog = std.StaticStringMap(RoleCatalog).initComptime(.{
    .{ "Assistant", RoleCatalog{
        .capabilities = &.{
            .{ .name = "assistant.read", .action_class = .silent },
            .{ .name = "assistant.propose", .action_class = .notify },
            .{ .name = "calendar.read", .action_class = .silent },
            .{ .name = "mail.read", .action_class = .silent },
            .{ .name = "files.read", .action_class = .silent },
            .{ .name = "calendar.commit", .action_class = .hold },
            .{ .name = "mail.send", .action_class = .hold },
        },
        .namespaces = &.{
            .{ .namespace = "assistant/workspace", .read = true, .write = true },
        },
    } },
    .{ "Calendar agent", RoleCatalog{
        .capabilities = &.{
            .{ .name = "calendar.read", .action_class = .silent },
            .{ .name = "calendar.propose", .action_class = .notify },
            .{ .name = "calendar.commit", .action_class = .hold },
        },
        .namespaces = &.{
            .{ .namespace = "calendar/personal", .read = true, .write = true },
        },
    } },
    .{ "Mail agent", RoleCatalog{
        .capabilities = &.{
            .{ .name = "mail.read", .action_class = .silent },
            .{ .name = "mail.draft", .action_class = .notify },
            .{ .name = "mail.send", .action_class = .hold },
        },
        .namespaces = &.{
            .{ .namespace = "mail/personal", .read = true },
        },
    } },
    .{ "Web research agent", RoleCatalog{
        .capabilities = &.{
            .{ .name = "web.read", .action_class = .silent },
            .{ .name = "web.fetch", .action_class = .notify },
        },
        .namespaces = &.{
            .{ .namespace = "research/scratch", .read = true, .write = true },
        },
    } },
    .{ "Files agent", RoleCatalog{
        .capabilities = &.{
            .{ .name = "files.read", .action_class = .silent },
            .{ .name = "files.propose", .action_class = .notify },
            .{ .name = "files.write", .action_class = .hold },
            .{ .name = "files.delete", .action_class = .human_only },
        },
        .namespaces = &.{
            .{ .namespace = "files/personal", .read = true, .write = true, .delete = true },
        },
    } },
});

/// Whether a role has a catalog entry at all — the check a gate uses to prove no role ships without a
/// declared authority surface.
pub fn hasRole(role: []const u8) bool {
    return catalog.get(role) != null;
}

/// What derivation needs: the agent being provisioned, the root that will endorse it, the role whose
/// catalog names its authority, the approved envelope that bounds it, the agent's own public key, and when
/// the manifest expires.
pub const Params = struct {
    kind: provisioning.Kind,
    role: []const u8,
    envelope: provisioning.AuthorityEnvelope,
    subject: identity.PrincipalId,
    issuer: identity.PrincipalId,
    agent_public_key: [manifest.public_key_bytes]u8,
    expires_at: ?time.Timestamp,
};

/// A derived manifest together with the two arrays it borrows. The manifest carries no allocation of its
/// own, so the owner of a `Derived` must keep it alive for the manifest's lifetime and free it through
/// `deinit`. The capability names and namespace strings are static catalog literals and are never freed.
pub const Derived = struct {
    manifest: manifest.Manifest,
    capabilities: []manifest.CapabilityRequest,
    namespaces: []manifest.NamespaceGrant,

    pub fn deinit(derived: *Derived, gpa: std.mem.Allocator) void {
        gpa.free(derived.capabilities);
        gpa.free(derived.namespaces);
        derived.* = undefined;
    }
};

/// Derives the manifest an approved envelope expresses, in a single pass over the role's catalog.
///
/// Every field is the envelope mapped to its concrete form. A capability keeps its cataloged class unless
/// it is consequential, in which case it is floored at the envelope's approval class (never looser) — and
/// a consequential capability an envelope without consequential authority cannot hold is dropped entirely,
/// leaving read and propose only. Namespace reach past reading is withheld from an agent without
/// consequential authority. Budgets, delegation, and data class map one-to-one. The result is
/// deny-by-default: nothing the catalog does not name, and nothing the envelope does not permit, ever
/// reaches the manifest.
pub fn derive(gpa: std.mem.Allocator, params: Params) Error!Derived {
    const role = catalog.get(params.role) orelse return Error.UnknownRole;
    const floor = actionClass(params.envelope.approval);

    var kept: usize = 0;
    for (role.capabilities) |entry| {
        if (isConsequential(entry.action_class) and !params.envelope.consequential) continue;
        kept += 1;
    }

    const capabilities = try gpa.alloc(manifest.CapabilityRequest, kept);
    errdefer gpa.free(capabilities);
    var index: usize = 0;
    for (role.capabilities) |entry| {
        if (isConsequential(entry.action_class) and !params.envelope.consequential) continue;
        const class = if (isConsequential(entry.action_class)) moreRestrictive(entry.action_class, floor) else entry.action_class;
        capabilities[index] = .{ .name = entry.name, .action_class = class };
        index += 1;
    }

    const namespaces = try gpa.alloc(manifest.NamespaceGrant, role.namespaces.len);
    errdefer gpa.free(namespaces);
    for (role.namespaces, 0..) |grant, i| {
        namespaces[i] = if (params.envelope.consequential) grant else .{ .namespace = grant.namespace, .read = grant.read };
    }

    return .{
        .manifest = .{
            .subject = params.subject,
            .issuer = params.issuer,
            .kind = principalKind(params.kind),
            .public_key = params.agent_public_key,
            .expires_at = params.expires_at,
            .capabilities = capabilities,
            .namespaces_requested = namespaces,
            .namespaces_offered = &.{},
            .delegation = .{
                .may_delegate = params.envelope.delegation_depth > 0,
                .max_depth = params.envelope.delegation_depth,
            },
            .budgets = .{
                .cpu_ms = params.envelope.budget.cpu_ms,
                .memory_bytes = params.envelope.budget.memory_bytes,
                .model_tokens = params.envelope.budget.model_tokens,
                .monetary_cents = params.envelope.budget.monetary_cents,
                .interruptions = 0,
            },
            .data_class = dataClass(params.envelope.privacy),
        },
        .capabilities = capabilities,
        .namespaces = namespaces,
    };
}

/// The account's approval class and the manifest's action class are the same four-valued ordered scale in
/// two modules. This is the one conversion between them; the comptime block below pins the two enums to
/// agree so reordering either without the other fails to compile rather than silently downgrading a class.
pub fn actionClass(class: account.PolicyDomain.ApprovalClass) manifest.ActionClass {
    return switch (class) {
        .silent => .silent,
        .notify => .notify,
        .hold => .hold,
        .human_only => .human_only,
    };
}

/// The account's two-valued privacy maps into the manifest's four-valued data class. On-device data never
/// leaves; egress-permitted data is classed `personal` — the conservative "may leave" choice, since
/// `widensBeyond` compares data class by ordinal and a looser choice would silently widen every agent.
pub fn dataClass(privacy: account.PolicyDomain.Privacy) manifest.DataClass {
    return switch (privacy) {
        .on_device => .never_leaves_device,
        .may_egress => .personal,
    };
}

/// The principal kind a provisioning kind enrolls as — an embodied agent is a device principal, every
/// other kind an agent principal. The manifest's kind and the enrolled principal's kind derive from this
/// one mapping so they can never disagree.
pub fn principalKind(kind: provisioning.Kind) core.principal.Kind {
    return switch (kind) {
        .assistant, .application_bound, .external => .agent,
        .device => .device,
    };
}

fn isConsequential(class: manifest.ActionClass) bool {
    return @intFromEnum(class) >= @intFromEnum(manifest.ActionClass.hold);
}

fn moreRestrictive(a: manifest.ActionClass, b: manifest.ActionClass) manifest.ActionClass {
    return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
}

comptime {
    const Approval = account.PolicyDomain.ApprovalClass;
    const Action = manifest.ActionClass;
    const approval_fields = @typeInfo(Approval).@"enum".fields;
    const action_fields = @typeInfo(Action).@"enum".fields;
    if (approval_fields.len != action_fields.len) {
        @compileError("approval and action classes must have the same values");
    }
    for (approval_fields, action_fields) |af, bf| {
        if (!std.mem.eql(u8, af.name, bf.name)) {
            @compileError("approval and action classes must agree name-for-name and in order");
        }
        if (@intFromEnum(actionClass(@field(Approval, af.name))) != @intFromEnum(@field(Approval, af.name))) {
            @compileError("approval-to-action conversion must preserve ordinal order");
        }
    }
}

// --- Tests ---

const testing = std.testing;
const roster = @import("roster.zig");

test "the approval and action class scales agree, so neither can drift" {
    // The comptime block already pins this; asserting it at runtime documents the contract.
    try testing.expectEqual(manifest.ActionClass.silent, actionClass(.silent));
    try testing.expectEqual(manifest.ActionClass.notify, actionClass(.notify));
    try testing.expectEqual(manifest.ActionClass.hold, actionClass(.hold));
    try testing.expectEqual(manifest.ActionClass.human_only, actionClass(.human_only));
}

test "privacy maps to the conservative may-leave data class" {
    try testing.expectEqual(manifest.DataClass.never_leaves_device, dataClass(.on_device));
    try testing.expectEqual(manifest.DataClass.personal, dataClass(.may_egress));
}

fn deriveFor(role: []const u8, envelope: provisioning.AuthorityEnvelope) !Derived {
    return derive(testing.allocator, .{
        .kind = .application_bound,
        .role = role,
        .envelope = envelope,
        .subject = .{ .value = 0xA },
        .issuer = .{ .value = 0x1 },
        .agent_public_key = @splat(0),
        .expires_at = .fromSeconds(10_000),
    });
}

test "a conservative envelope yields a read-and-propose manifest with no consequential authority" {
    var derived = try deriveFor("Calendar agent", .{});
    defer derived.deinit(testing.allocator);

    // Read and propose survive; the consequential commit is dropped entirely — deny by default.
    try testing.expect(derived.manifest.permits("calendar.read"));
    try testing.expect(derived.manifest.permits("calendar.propose"));
    try testing.expect(!derived.manifest.permits("calendar.commit"));
    // Namespace reach past reading is withheld without consequential authority.
    try testing.expect(derived.manifest.namespaces_requested[0].read);
    try testing.expect(!derived.manifest.namespaces_requested[0].write);
    try testing.expectEqual(manifest.DataClass.never_leaves_device, derived.manifest.data_class);
}

test "granting consequential authority admits the consequential capability at the envelope's floor" {
    var derived = try deriveFor("Calendar agent", .{ .consequential = true, .approval = .human_only });
    defer derived.deinit(testing.allocator);

    // The commit is now present, floored at the envelope's approval class, never looser than the catalog.
    try testing.expectEqual(manifest.ActionClass.human_only, derived.manifest.classOf("calendar.commit").?);
    // A read stays silent — the floor applies to consequential operations, not to reading.
    try testing.expectEqual(manifest.ActionClass.silent, derived.manifest.classOf("calendar.read").?);
    // Consequential authority restores full namespace reach.
    try testing.expect(derived.manifest.namespaces_requested[0].write);
}

test "an unknown role is refused rather than issued an empty manifest" {
    try testing.expectError(Error.UnknownRole, deriveFor("no such role", .{}));
}

test "derive leaks nothing when either of its two allocations fails" {
    // Deriving allocates the capability array and then the namespace array; a failure at the second must
    // release the first through its errdefer. A consequential envelope keeps every cataloged capability, so
    // both allocations are exercised.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var derived = try derive(gpa, .{
                .kind = .application_bound,
                .role = "Files agent",
                .envelope = .{ .consequential = true, .approval = .hold },
                .subject = .{ .value = 0xA },
                .issuer = .{ .value = 0x1 },
                .agent_public_key = @splat(0),
                .expires_at = .fromSeconds(10_000),
            });
            derived.deinit(gpa);
        }
    }.run, .{});
}

test "every default-agent role has a catalog entry whose derived manifest stays within its ceiling" {
    // The gate: the shipped first-run set never names a role without an authority surface, and a default
    // agent's conservative manifest never widens beyond the most authority its role could ever hold.
    for (roster.default_agents) |da| {
        try testing.expect(hasRole(da.role));

        var derived = try derive(testing.allocator, .{
            .kind = da.kind,
            .role = da.role,
            .envelope = da.envelope,
            .subject = .{ .value = 0xA },
            .issuer = .{ .value = 0x1 },
            .agent_public_key = @splat(0),
            .expires_at = .fromSeconds(10_000),
        });
        defer derived.deinit(testing.allocator);

        // The ceiling: the same role at the loosest envelope the account could ever approve.
        var ceiling = try derive(testing.allocator, .{
            .kind = da.kind,
            .role = da.role,
            .envelope = .{
                .consequential = true,
                .approval = .silent,
                .privacy = .may_egress,
                .budget = .{ .cpu_ms = 1 << 40, .memory_bytes = 1 << 40, .model_tokens = 1 << 40, .monetary_cents = 1 << 40 },
                .delegation_depth = 255,
            },
            .subject = .{ .value = 0xA },
            .issuer = .{ .value = 0x1 },
            .agent_public_key = @splat(0),
            .expires_at = .fromSeconds(10_000),
        });
        defer ceiling.deinit(testing.allocator);

        try testing.expect(!derived.manifest.widensBeyond(ceiling.manifest));
    }
}
