//! Deciding whether an agent may read a knowledge entry and what trust that entry
//! carries, so an agent draws on knowledge it is scoped to and never mistakes ingested
//! content for a vetted fact.
//!
//! An agent's knowledge base holds two very different things under one roof. Some
//! entries are curated: facts a trusted source vetted, the kind an agent may rely on
//! to reason and act. Others are ingested: text pulled in from documents and the web,
//! useful as reference but no more trustworthy than where it came from. Treating them
//! alike is the mistake — an agent that reads an ingested claim as a vetted fact acts
//! on unverified, possibly adversarial, information. So a knowledge entry carries its
//! provenance, and reading it hands back that provenance unchanged, so the agent knows
//! whether it is standing on solid ground. Access is also scoped: an entry belongs to
//! a knowledge domain, and an agent reads only the domains it was granted, so one
//! agent's knowledge base is not a window into another's. Scoped access and preserved
//! provenance together let an agent know both what it may read and how far to trust it.
//!
//! This module stores nothing. It decides whether an agent may read an entry and what
//! provenance the read carries, as pure functions over the grant and the entry.

const std = @import("std");

/// How trusted a knowledge entry is.
pub const Provenance = enum {
    /// Curated and vetted by a trusted source. May be relied on.
    curated,
    /// Ingested from a document or the web. Reference only; no more trusted than its
    /// origin.
    ingested,
};

/// A knowledge entry.
pub const Entry = struct {
    /// The domain this entry belongs to. An agent reads only granted domains.
    domain: []const u8,
    provenance: Provenance,
};

/// The domains an agent is granted to read.
pub const Grant = struct {
    domains: []const []const u8,

    fn covers(grant: Grant, domain: []const u8) bool {
        for (grant.domains) |granted| {
            if (std.mem.eql(u8, granted, domain)) return true;
        }
        return false;
    }
};

/// The outcome of a knowledge read.
pub const Read = union(enum) {
    /// The read is permitted; the content carries this provenance.
    allow: Provenance,
    /// The agent is not scoped to this entry's domain.
    denied,

    pub fn allowed(result: Read) bool {
        return result == .allow;
    }
};

/// Decides whether an agent may read an entry, and with what trust.
///
/// The agent must be granted the entry's domain, or the read is denied — one agent's
/// knowledge is not another's. A permitted read returns the entry's provenance
/// unchanged, so an ingested entry is never handed back as curated: the agent always
/// knows whether what it read is a vetted fact or unverified reference.
pub fn read(grant: Grant, entry: Entry) Read {
    if (!grant.covers(entry.domain)) return .denied;
    return .{ .allow = entry.provenance };
}

const sample_grant: Grant = .{ .domains = &.{ "calendar", "contacts" } };

test "an agent reads an entry in a granted domain" {
    const entry: Entry = .{ .domain = "calendar", .provenance = .curated };
    try std.testing.expectEqual(Read{ .allow = .curated }, read(sample_grant, entry));
}

test "an agent is denied an entry outside its granted domains" {
    const entry: Entry = .{ .domain = "finance", .provenance = .curated };
    try std.testing.expectEqual(Read.denied, read(sample_grant, entry));
}

test "a read preserves the entry's provenance" {
    const ingested: Entry = .{ .domain = "contacts", .provenance = .ingested };
    try std.testing.expectEqual(Read{ .allow = .ingested }, read(sample_grant, ingested));
    const curated: Entry = .{ .domain = "contacts", .provenance = .curated };
    try std.testing.expectEqual(Read{ .allow = .curated }, read(sample_grant, curated));
}

test "an ingested entry is never handed back as curated, swept" {
    // The no-blessing property: a permitted read returns exactly the stored
    // provenance, so ingested content is never elevated to curated.
    for (std.enums.values(Provenance)) |provenance| {
        const entry: Entry = .{ .domain = "calendar", .provenance = provenance };
        switch (read(sample_grant, entry)) {
            .allow => |returned| try std.testing.expectEqual(provenance, returned),
            .denied => return error.TestUnexpectedResult,
        }
    }
}

test "an empty grant reads nothing" {
    const empty: Grant = .{ .domains = &.{} };
    try std.testing.expectEqual(Read.denied, read(empty, .{ .domain = "calendar", .provenance = .curated }));
}
