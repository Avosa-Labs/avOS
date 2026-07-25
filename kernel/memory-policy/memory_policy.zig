//! Which allocator a piece of work is allowed to draw from, and what that
//! choice guarantees.
//!
//! Zig's allocator model is a platform feature rather than an implementation
//! detail, so the system does not have one heap. It has domains, each with a
//! lifetime and a discipline, and work belongs to exactly one of them. This
//! module is the policy that says which — it allocates nothing itself, it
//! decides which domain a request belongs in and refuses the requests a domain
//! must not serve.
//!
//! The reason to make this a decision rather than a convention is that the most
//! damaging allocation bugs are category errors: a secret placed in a heap that
//! gets swapped to disk, a per-request buffer kept in a long-lived arena that
//! never frees it, a real-time path that reaches for a growable allocator and
//! stalls on a page fault. Each is invisible in a code review of the call site
//! and obvious once the domain rules are stated and checked.

const std = @import("std");

/// The allocator domains, each a distinct lifetime and discipline.
///
/// A request belongs to one domain. Which one is a policy decision, not the
/// caller's preference, because the caller is exactly who does not see the
/// system-wide consequence of getting it wrong.
pub const Domain = enum {
    /// Boot and early initialization. Allocated once, never freed, gone when
    /// boot hands off. Nothing that outlives boot may live here.
    boot,
    /// Trusted long-lived services: the control plane and its peers. Freed only
    /// at shutdown.
    trusted_service,
    /// One request's working set. Freed when the request completes, all at once.
    per_request,
    /// One task's working set, across the request boundary. Freed when the task
    /// ends or is cancelled.
    per_task,
    /// One agent's working set: retrieval, planning, context. Bounded per agent.
    per_agent,
    /// Fixed real-time buffers, sized ahead of time. Never grows on the hot
    /// path, because growth means a page fault means a missed deadline.
    real_time,
    /// Secrets: keys, tokens, credentials in use. Never swapped, always zeroed
    /// on release.
    secret,
    /// Shared transport buffers: IPC rings, the one place shared mutable memory
    /// is expected.
    shared_transport,
    /// Compatibility runtimes: the Android and WebAssembly guests. Bounded and
    /// billed to the guest, never to the host.
    compatibility_runtime,
    /// Diagnostics and tests. Present in every build so a diagnostic path is
    /// never a special case that only exists in one.
    diagnostics,

    pub const count = std.enums.values(Domain).len;
};

/// The properties a domain guarantees.
///
/// Stated as data so a request can be matched against what it needs rather than
/// against a domain name someone hopes is the right one.
pub const Discipline = struct {
    /// Whether memory here may be paged to disk. False for anything holding a
    /// secret, because a swapped secret is a secret written somewhere nobody
    /// chose to write it.
    swappable: bool,
    /// Whether memory here is wiped on release. True for secrets, so a freed key
    /// does not linger in a reused page.
    zeroed_on_release: bool,
    /// Whether an allocation here may grow after it is made. False for real-time
    /// buffers, whose whole purpose is to never fault on the hot path.
    growable: bool,
    /// Whether the domain has a hard ceiling. A domain without one can exhaust
    /// the device; only boot and the trusted services, which are bounded by
    /// construction, are allowed to lack a numeric cap.
    bounded: bool,
    /// The hard ceiling in bytes, or zero when the domain is unbounded. A domain
    /// that claims a ceiling must name it, so a request can be checked against a
    /// number rather than against a promise.
    ceiling_bytes: usize,
    /// When memory here is reclaimed.
    lifetime: Lifetime,

    pub const Lifetime = enum {
        /// Freed only when the whole system stops.
        until_shutdown,
        /// Freed when a request, task, or agent ends.
        until_scope_ends,
        /// Freed explicitly by whoever allocated it.
        manual,
    };
};

/// The discipline each domain provides. This is the table the rest of the
/// module reasons against.
pub fn disciplineOf(domain: Domain) Discipline {
    return switch (domain) {
        .boot => .{
            .swappable = false,
            .zeroed_on_release = false,
            .growable = true,
            .bounded = false,
            .ceiling_bytes = 0,
            .lifetime = .until_shutdown,
        },
        .trusted_service => .{
            .swappable = true,
            .zeroed_on_release = false,
            .growable = true,
            .bounded = false,
            .ceiling_bytes = 0,
            .lifetime = .until_shutdown,
        },
        .per_request, .per_task, .per_agent => .{
            .swappable = true,
            .zeroed_on_release = false,
            .growable = true,
            .bounded = true,
            .ceiling_bytes = 16 * 1024 * 1024,
            .lifetime = .until_scope_ends,
        },
        .real_time => .{
            .swappable = false,
            .zeroed_on_release = false,
            .growable = false,
            .bounded = true,
            .ceiling_bytes = 2 * 1024 * 1024,
            .lifetime = .manual,
        },
        .secret => .{
            .swappable = false,
            .zeroed_on_release = true,
            .growable = false,
            .bounded = true,
            .ceiling_bytes = 256 * 1024,
            .lifetime = .manual,
        },
        .shared_transport => .{
            .swappable = false,
            .zeroed_on_release = false,
            .growable = false,
            .bounded = true,
            .ceiling_bytes = 4 * 1024 * 1024,
            .lifetime = .manual,
        },
        .compatibility_runtime => .{
            .swappable = true,
            .zeroed_on_release = false,
            .growable = true,
            .bounded = true,
            .ceiling_bytes = 128 * 1024 * 1024,
            .lifetime = .until_scope_ends,
        },
        .diagnostics => .{
            .swappable = true,
            .zeroed_on_release = false,
            .growable = true,
            .bounded = true,
            .ceiling_bytes = 8 * 1024 * 1024,
            .lifetime = .until_scope_ends,
        },
    };
}

/// What a request needs from a domain.
pub const Requirement = struct {
    /// The request holds a secret. It must land somewhere unswappable and
    /// zeroed.
    holds_secret: bool = false,
    /// The request is on a real-time deadline. It must not be able to fault on
    /// a growth.
    real_time: bool = false,
    /// The request outlives the scope it is made in. It must not be placed in a
    /// domain that frees when the scope ends.
    outlives_scope: bool = false,
    /// The request is unbounded work whose ceiling matters.
    needs_ceiling: bool = false,
};

pub const Error = error{
    /// No domain satisfies the requirement, or the named one does not.
    DomainUnsuitable,
};

/// Whether a domain satisfies a requirement.
///
/// The check the whole module exists for. A secret in a swappable domain, a
/// real-time buffer that can grow, work that outlives a scope-freed domain — all
/// three are the category errors that cost most and show least, and each is a
/// mismatch this returns false for.
pub fn satisfies(domain: Domain, requirement: Requirement) bool {
    const discipline = disciplineOf(domain);

    if (requirement.holds_secret) {
        if (discipline.swappable) return false;
        if (!discipline.zeroed_on_release) return false;
    }
    if (requirement.real_time and discipline.growable) return false;
    if (requirement.outlives_scope and discipline.lifetime == .until_scope_ends) return false;
    if (requirement.needs_ceiling and !discipline.bounded) return false;

    return true;
}

/// Checks that a caller's chosen domain is one the request may use.
///
/// Placing work is a decision the platform makes, so a caller states what its
/// work needs and the policy confirms the domain is suitable rather than
/// trusting that it picked correctly.
pub fn place(domain: Domain, requirement: Requirement) Error!void {
    if (!satisfies(domain, requirement)) return error.DomainUnsuitable;
}

/// Whether granting `requested_bytes` on top of `in_use` would cross the domain's
/// ceiling.
///
/// An unbounded domain never exceeds. For a bounded one, the sum is computed with
/// overflow rejected: a request whose size plus what is already in use does not
/// fit in the counter is treated as exceeding rather than wrapping to a small
/// number that would slip under the ceiling.
pub fn wouldExceed(domain: Domain, requested_bytes: usize, in_use: usize) bool {
    const discipline = disciplineOf(domain);
    if (!discipline.bounded) return false;
    const total = std.math.add(usize, in_use, requested_bytes) catch return true;
    return total > discipline.ceiling_bytes;
}

/// The domain a secret must use.
///
/// There is exactly one, and naming it as a function means a caller cannot
/// accidentally put a key anywhere else and cannot be talked into it by a
/// configuration value.
pub fn secretDomain() Domain {
    return .secret;
}

test "a bounded domain refuses a request that crosses its ceiling" {
    const ceiling = disciplineOf(.real_time).ceiling_bytes;
    // Just under the ceiling is fine; the request that crosses it is refused.
    try std.testing.expect(!wouldExceed(.real_time, 1024, ceiling - 2048));
    try std.testing.expect(wouldExceed(.real_time, 4096, ceiling - 2048));
    // Exactly at the ceiling is allowed; one byte over is not.
    try std.testing.expect(!wouldExceed(.real_time, ceiling, 0));
    try std.testing.expect(wouldExceed(.real_time, ceiling + 1, 0));
}

test "an unbounded domain never reports exceeding" {
    try std.testing.expect(!wouldExceed(.boot, std.math.maxInt(usize), 0));
    try std.testing.expect(!wouldExceed(.trusted_service, 1 << 40, 1 << 40));
}

test "a request that overflows the counter is treated as exceeding" {
    // The sum wraps if computed unchecked; it must be refused, not wrapped.
    try std.testing.expect(wouldExceed(.secret, std.math.maxInt(usize), 1));
}

test "the domain table covers every domain" {
    // A domain without a discipline would be a hole the checks below cannot see.
    for (std.enums.values(Domain)) |domain| {
        _ = disciplineOf(domain);
    }
    try std.testing.expectEqual(@as(usize, 10), Domain.count);
}

test "a secret only fits an unswappable, zeroed domain" {
    const requirement: Requirement = .{ .holds_secret = true };

    // The secret domain is the one that fits.
    try std.testing.expect(satisfies(.secret, requirement));
    try place(.secret, requirement);

    // A swapped secret is a secret written to disk nobody chose to write.
    try std.testing.expect(!satisfies(.trusted_service, requirement));
    try std.testing.expect(!satisfies(.per_request, requirement));
    try std.testing.expect(!satisfies(.diagnostics, requirement));
    try std.testing.expectError(error.DomainUnsuitable, place(.trusted_service, requirement));
}

test "the only home for a secret is the secret domain" {
    // Swept: of every domain, exactly one holds a secret.
    var fits: usize = 0;
    for (std.enums.values(Domain)) |domain| {
        if (satisfies(domain, .{ .holds_secret = true })) {
            try std.testing.expectEqual(Domain.secret, domain);
            fits += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fits);
    try std.testing.expectEqual(Domain.secret, secretDomain());
}

test "real-time work cannot land in a growable domain" {
    const requirement: Requirement = .{ .real_time = true };

    // A real-time buffer that can grow faults on the hot path and misses a
    // deadline.
    try std.testing.expect(satisfies(.real_time, requirement));
    try std.testing.expect(!satisfies(.per_task, requirement));
    try std.testing.expect(!satisfies(.trusted_service, requirement));

    // shared_transport is also fixed, so a real-time IPC ring is allowed.
    try std.testing.expect(satisfies(.shared_transport, requirement));
}

test "work that outlives its scope cannot use a scope-freed domain" {
    const requirement: Requirement = .{ .outlives_scope = true };

    // Kept in a per-request arena, it would be freed the moment the request
    // ends, out from under whoever still holds it.
    try std.testing.expect(!satisfies(.per_request, requirement));
    try std.testing.expect(!satisfies(.per_task, requirement));
    try std.testing.expect(!satisfies(.per_agent, requirement));

    // A long-lived service or a manually managed buffer is fine.
    try std.testing.expect(satisfies(.trusted_service, requirement));
    try std.testing.expect(satisfies(.real_time, requirement));
}

test "unbounded work needs a domain with a ceiling" {
    const requirement: Requirement = .{ .needs_ceiling = true };

    // Only boot and the trusted services lack a numeric ceiling, because both
    // are bounded by construction rather than by a cap.
    try std.testing.expect(!satisfies(.boot, requirement));
    try std.testing.expect(!satisfies(.trusted_service, requirement));
    try std.testing.expect(satisfies(.per_request, requirement));
    try std.testing.expect(satisfies(.per_agent, requirement));
}

test "a request with several requirements must satisfy all of them" {
    // A secret on a real-time path: needs unswappable, zeroed, and non-growable.
    const requirement: Requirement = .{ .holds_secret = true, .real_time = true };

    // The secret domain is unswappable, zeroed, and not growable, so it fits.
    try std.testing.expect(satisfies(.secret, requirement));

    // The real-time domain is unswappable and non-growable but not zeroed, so a
    // secret must not use it.
    try std.testing.expect(!satisfies(.real_time, requirement));
}

test "a request with no special requirement fits an ordinary domain" {
    const requirement: Requirement = .{};
    try std.testing.expect(satisfies(.per_request, requirement));
    try place(.per_request, requirement);
}

test "boot memory is never swappable" {
    // Early initialization runs before the paging that could swap it exists.
    try std.testing.expect(!disciplineOf(.boot).swappable);
}

test "every scope-freed domain frees when its scope ends" {
    for ([_]Domain{ .per_request, .per_task, .per_agent }) |domain| {
        try std.testing.expectEqual(
            Discipline.Lifetime.until_scope_ends,
            disciplineOf(domain).lifetime,
        );
    }
}
