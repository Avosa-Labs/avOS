//! What untrusted code is allowed to reach, which by default is nothing.
//!
//! A sandbox is the boundary an untrusted component runs inside: a compatibility
//! guest, a downloaded package, a model's tool call. The one property that makes
//! it a sandbox rather than a suggestion is that it denies by default. Code
//! inside reaches nothing it was not explicitly, individually granted, so a
//! capability the author forgot to remove is not a capability the code has — the
//! author has to add each one, and each addition is a visible decision that can
//! be reviewed and audited.
//!
//! This is the policy, not the enforcement. Enforcement is the runtime's job:
//! the WebAssembly host that refuses an import, the process boundary that blocks
//! a syscall. What lives here is the decision those enforcers consult — is this
//! reach one this sandbox's grants permit — computed as a pure function so the
//! deny-by-default property is verified rather than assumed, and so a sandbox's
//! whole permitted surface can be inspected before any code runs in it.

const std = @import("std");

/// A resource an untrusted component might try to reach.
///
/// Coarse categories, because the sandbox boundary is about kind of access, not
/// individual objects: a component either may open network connections or may
/// not. Fine-grained control within a granted category is the capability
/// system's job, one layer in.
pub const Resource = enum {
    /// Read from storage the component was given.
    read_storage,
    /// Write to storage the component was given.
    write_storage,
    /// Open outbound network connections.
    network,
    /// Reach a device class (camera, location, and so on), still subject to the
    /// device policy above it.
    device,
    /// Spawn child work.
    spawn,
    /// Reach the clock and timers. Even this is a grant, because a precise clock
    /// is a side channel a sandbox may wish to deny.
    clock,
    /// Draw to a surface the component owns.
    render,

    pub const count = std.enums.values(Resource).len;

    /// Whether reaching this resource can send a person's data off the device.
    ///
    /// The reaches that most need a deliberate grant, because their misuse is
    /// exfiltration rather than mere misbehaviour.
    pub fn canExfiltrate(resource: Resource) bool {
        return resource == .network or resource == .write_storage;
    }
};

/// Why a reach was refused.
pub const Refusal = enum {
    /// The sandbox does not grant this resource. The default answer.
    not_granted,
    /// The resource is granted, but its per-use budget is spent.
    budget_exhausted,
    /// The sandbox has been revoked; it grants nothing now.
    revoked,
};

/// The outcome of a reach attempt.
pub const Decision = union(enum) {
    allow,
    deny: Refusal,

    pub fn isAllowed(decision: Decision) bool {
        return decision == .allow;
    }
};

/// The grants a sandbox holds, and its state.
///
/// Starts empty: a fresh sandbox permits nothing, so the safe configuration is
/// the one you get by doing nothing, and every permission is an addition.
pub const Sandbox = struct {
    /// Which resources are granted. Absent means denied.
    granted: std.EnumSet(Resource) = .initEmpty(),
    /// How many reaches remain for each resource, when a budget applies. A value
    /// of null means unlimited within the grant; zero means the budget is spent.
    remaining: [Resource.count]?u32 = @splat(null),
    /// Once revoked, the sandbox grants nothing, whatever it held.
    revoked: bool = false,

    /// Grants a resource, optionally with a use budget.
    ///
    /// Each grant is a separate, explicit call, so adding a permission is a
    /// visible act. There is deliberately no "grant all".
    pub fn grant(sandbox: *Sandbox, resource: Resource, budget: ?u32) void {
        sandbox.granted.insert(resource);
        sandbox.remaining[@intFromEnum(resource)] = budget;
    }

    /// Decides whether a reach is permitted, without consuming budget.
    ///
    /// A pure query: the same inputs give the same answer, and it never mutates,
    /// so a caller can check before committing to an action. Consumption is a
    /// separate, explicit step.
    pub fn permits(sandbox: Sandbox, resource: Resource) Decision {
        if (sandbox.revoked) return .{ .deny = .revoked };
        if (!sandbox.granted.contains(resource)) return .{ .deny = .not_granted };
        if (sandbox.remaining[@intFromEnum(resource)]) |left| {
            if (left == 0) return .{ .deny = .budget_exhausted };
        }
        return .allow;
    }

    /// Attempts a reach, consuming one unit of budget if it is permitted.
    ///
    /// The form an enforcer calls when it is about to actually let code through:
    /// it both decides and records the use, so a budgeted resource cannot be
    /// used more times than granted by checking and acting separately.
    pub fn attempt(sandbox: *Sandbox, resource: Resource) Decision {
        const decision = sandbox.permits(resource);
        if (decision.isAllowed()) {
            if (sandbox.remaining[@intFromEnum(resource)]) |*left| {
                left.* -= 1;
            }
        }
        return decision;
    }

    /// Revokes the sandbox. Everything is denied from here, immediately.
    ///
    /// The response to a component that misbehaved: one call closes the whole
    /// boundary, rather than having to remember and remove each grant.
    pub fn revoke(sandbox: *Sandbox) void {
        sandbox.revoked = true;
    }

    /// The resources this sandbox currently permits, for inspection before code
    /// runs.
    ///
    /// Lets a reviewer or an audit record enumerate a sandbox's whole permitted
    /// surface, which is only possible because the surface is explicit and
    /// bounded.
    pub fn permittedSurface(sandbox: Sandbox, into: []Resource) []const Resource {
        if (sandbox.revoked) return into[0..0];
        var count: usize = 0;
        for (std.enums.values(Resource)) |resource| {
            if (count >= into.len) break;
            if (sandbox.permits(resource).isAllowed()) {
                into[count] = resource;
                count += 1;
            }
        }
        return into[0..count];
    }
};

test "a fresh sandbox permits nothing" {
    // The deny-by-default property: the configuration you get for free is the
    // safe one.
    const sandbox: Sandbox = .{};
    for (std.enums.values(Resource)) |resource| {
        try std.testing.expectEqual(Decision{ .deny = .not_granted }, sandbox.permits(resource));
    }
}

test "a granted resource is permitted and others stay denied" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.render, null);
    try std.testing.expect(sandbox.permits(.render).isAllowed());
    // Granting one thing grants only that thing.
    try std.testing.expect(!sandbox.permits(.network).isAllowed());
    try std.testing.expect(!sandbox.permits(.read_storage).isAllowed());
}

test "a budgeted resource is spent by use" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.network, 2);
    try std.testing.expect(sandbox.attempt(.network).isAllowed());
    try std.testing.expect(sandbox.attempt(.network).isAllowed());
    // The third attempt is refused: a budget is a hard ceiling.
    try std.testing.expectEqual(Decision{ .deny = .budget_exhausted }, sandbox.attempt(.network));
}

test "checking does not consume budget" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.network, 1);
    // permits is a pure query; only attempt consumes.
    try std.testing.expect(sandbox.permits(.network).isAllowed());
    try std.testing.expect(sandbox.permits(.network).isAllowed());
    try std.testing.expect(sandbox.attempt(.network).isAllowed());
    try std.testing.expect(!sandbox.permits(.network).isAllowed());
}

test "an unbudgeted grant is used without limit" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.clock, null);
    for (0..1000) |_| try std.testing.expect(sandbox.attempt(.clock).isAllowed());
}

test "revocation denies everything at once" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.render, null);
    sandbox.grant(.read_storage, null);
    sandbox.revoke();
    // One call closes the whole boundary.
    try std.testing.expectEqual(Decision{ .deny = .revoked }, sandbox.permits(.render));
    try std.testing.expectEqual(Decision{ .deny = .revoked }, sandbox.permits(.read_storage));
}

test "the permitted surface can be inspected before code runs" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.render, null);
    sandbox.grant(.clock, null);

    var buffer: [Resource.count]Resource = undefined;
    const surface = sandbox.permittedSurface(&buffer);
    try std.testing.expectEqual(@as(usize, 2), surface.len);

    // A reviewer can enumerate exactly what the sandbox allows.
    var has_render = false;
    var has_clock = false;
    for (surface) |resource| {
        if (resource == .render) has_render = true;
        if (resource == .clock) has_clock = true;
    }
    try std.testing.expect(has_render and has_clock);
}

test "a revoked sandbox has an empty permitted surface" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.network, null);
    sandbox.revoke();
    var buffer: [Resource.count]Resource = undefined;
    try std.testing.expectEqual(@as(usize, 0), sandbox.permittedSurface(&buffer).len);
}

test "a spent budget leaves the resource off the permitted surface" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.network, 1);
    _ = sandbox.attempt(.network);

    var buffer: [Resource.count]Resource = undefined;
    const surface = sandbox.permittedSurface(&buffer);
    for (surface) |resource| try std.testing.expect(resource != .network);
}

test "the exfiltration-capable resources are network and write" {
    // The reaches whose grant most needs deliberation, because misuse is
    // exfiltration.
    try std.testing.expect(Resource.network.canExfiltrate());
    try std.testing.expect(Resource.write_storage.canExfiltrate());
    try std.testing.expect(!Resource.read_storage.canExfiltrate());
    try std.testing.expect(!Resource.render.canExfiltrate());
    try std.testing.expect(!Resource.clock.canExfiltrate());
}

test "granting the same resource again resets its budget deliberately" {
    var sandbox: Sandbox = .{};
    sandbox.grant(.network, 1);
    _ = sandbox.attempt(.network);
    try std.testing.expect(!sandbox.permits(.network).isAllowed());
    // Re-granting is an explicit act that resets the budget; it is not implicit.
    sandbox.grant(.network, 3);
    try std.testing.expect(sandbox.permits(.network).isAllowed());
}

test "there is no way to grant everything at once" {
    // Structural: the sandbox exposes grant (one resource) and never a grant-all,
    // so permitting the whole surface takes N deliberate calls.
    const decls = @typeInfo(Sandbox).@"struct".decls;
    inline for (decls) |decl| {
        const forbidden = [_][]const u8{ "grantAll", "grantEverything", "allowAll" };
        for (forbidden) |name| {
            try std.testing.expect(!std.mem.eql(u8, decl.name, name));
        }
    }
}
