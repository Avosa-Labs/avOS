//! Deciding whether an agent may be admitted to run, and under what bounds, so an
//! agent starts only with authority it was granted and a budget it cannot exceed.
//!
//! An agent is a principal that runs code driven by a model, and admitting one to
//! run is the moment its authority and its resource envelope are fixed. Get that
//! moment wrong and everything after is unsafe: an agent admitted with capabilities
//! it was never granted can act beyond its mandate, and one admitted with no resource
//! ceiling can run away and starve the device. So the host does not simply launch
//! what it is handed. It checks the agent's manifest against what the requester is
//! actually authorized to confer — an agent cannot be granted a capability its
//! creator does not hold — and it binds a resource budget the agent runs within,
//! refusing a manifest that asks for more authority than is available or omits the
//! budget that bounds it. Admission is where a runaway or over-privileged agent is
//! stopped, before it has run a single step.
//!
//! This module launches no agent. It decides whether a manifest may be admitted given
//! the authority the requester holds, as a pure function over the two, so the bound is
//! set in one place.

const std = @import("std");

/// What an agent's manifest declares it needs to run.
pub const Manifest = struct {
    /// The capabilities the agent requests, as a bitset of coarse authority classes.
    requested: Authority,
    /// The resource budget the agent will run within, in units. Zero is invalid: an
    /// agent with no budget has no bound.
    budget_units: u64,
};

/// A coarse set of authority classes an agent may hold. Fine-grained capabilities
/// live in the capability model; this is the envelope checked at admission.
pub const Authority = std.EnumSet(Class);

/// A class of authority.
pub const Class = enum {
    /// Read local data.
    read,
    /// Make local, reversible changes.
    local_write,
    /// Reach off the device.
    network,
    /// Effects with real-world consequence: send, pay, grant.
    consequential,
};

/// Why admission was refused.
pub const Refusal = enum {
    /// The manifest requests authority the granting principal does not itself hold,
    /// which would let admission escalate privilege.
    exceeds_grantor_authority,
    /// The manifest declares no resource budget, so the agent would be unbounded.
    no_budget,
};

/// The admission decision.
pub const Decision = union(enum) {
    /// The agent is admitted with this resource budget.
    admit: u64,
    refuse: Refusal,

    pub fn admitted(decision: Decision) bool {
        return decision == .admit;
    }
};

/// Decides whether an agent may be admitted, given the authority its grantor holds.
///
/// The requested authority must be a subset of the grantor's — an agent can never be
/// admitted with a capability class its creator does not hold, so admission cannot
/// manufacture privilege. And the manifest must declare a non-zero budget, because an
/// agent without a resource ceiling is a runaway waiting to happen. A manifest that
/// passes both is admitted with its declared budget as its hard ceiling.
pub fn admit(manifest: Manifest, grantor_authority: Authority) Decision {
    if (!manifest.requested.subsetOf(grantor_authority)) {
        return .{ .refuse = .exceeds_grantor_authority };
    }
    if (manifest.budget_units == 0) return .{ .refuse = .no_budget };
    return .{ .admit = manifest.budget_units };
}

fn authorityOf(classes: []const Class) Authority {
    var authority: Authority = .initEmpty();
    for (classes) |class| authority.insert(class);
    return authority;
}

test "an agent within the grantor's authority is admitted with its budget" {
    const manifest: Manifest = .{ .requested = authorityOf(&.{ .read, .local_write }), .budget_units = 1000 };
    const grantor = authorityOf(&.{ .read, .local_write, .network });
    try std.testing.expectEqual(Decision{ .admit = 1000 }, admit(manifest, grantor));
}

test "an agent requesting more than the grantor holds is refused" {
    const manifest: Manifest = .{ .requested = authorityOf(&.{.consequential}), .budget_units = 1000 };
    const grantor = authorityOf(&.{ .read, .local_write });
    try std.testing.expectEqual(Decision{ .refuse = .exceeds_grantor_authority }, admit(manifest, grantor));
}

test "an agent with no budget is refused" {
    const manifest: Manifest = .{ .requested = authorityOf(&.{.read}), .budget_units = 0 };
    const grantor = authorityOf(&.{.read});
    try std.testing.expectEqual(Decision{ .refuse = .no_budget }, admit(manifest, grantor));
}

test "an agent requesting exactly the grantor's authority is admitted" {
    const classes = [_]Class{ .read, .network };
    const manifest: Manifest = .{ .requested = authorityOf(&classes), .budget_units = 500 };
    try std.testing.expect(admit(manifest, authorityOf(&classes)).admitted());
}

test "an empty request is admitted with a budget" {
    const manifest: Manifest = .{ .requested = .initEmpty(), .budget_units = 100 };
    try std.testing.expect(admit(manifest, authorityOf(&.{.read})).admitted());
}

test "no admitted agent ever holds authority its grantor lacks, swept" {
    // The no-escalation property: whenever admission succeeds, every requested class
    // is one the grantor held.
    const grantor = authorityOf(&.{ .read, .local_write });
    const request_sets = [_][]const Class{
        &.{.read}, &.{ .read, .local_write }, &.{.network}, &.{ .read, .consequential },
    };
    for (request_sets) |classes| {
        const manifest: Manifest = .{ .requested = authorityOf(classes), .budget_units = 10 };
        if (admit(manifest, grantor).admitted()) {
            try std.testing.expect(manifest.requested.subsetOf(grantor));
        }
    }
}
