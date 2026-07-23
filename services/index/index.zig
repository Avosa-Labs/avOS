//! Deciding whether an item may be added to the searchable index, so the thing that
//! makes everything findable never quietly makes a secret findable too.
//!
//! An index is the counterpart to search: search can only trim what the index holds,
//! so the first line of defence is not to index what should never surface. Some
//! content is secret by nature — a password store, a private key, the contents of an
//! app that declared itself unsearchable — and adding it to a shared index is a leak
//! even before anyone searches, because the index is itself a copy of that content
//! in a place other things can reach. So indexing is opt-out for the sensitive: an
//! item marked secret, or belonging to a source that excluded itself from search, is
//! never indexed, whatever its content; ordinary content is indexed so it can be
//! found. What is protected is decided by the item's own classification, not by the
//! indexer's guess, so marking something secret keeps it out reliably.
//!
//! This module indexes nothing. It decides whether an item is eligible for the index
//! from its sensitivity and its source's search policy, as a pure function so the
//! keep-secrets-out rule holds in one place.

const std = @import("std");

/// How sensitive an item is, which decides whether it may be indexed at all.
pub const Sensitivity = enum {
    /// Ordinary content: documents, messages, media a person expects to find.
    ordinary,
    /// Secret content: credentials, keys, private notes. Never indexed.
    secret,
};

/// Whether an item's source permits its content to appear in search.
pub const SourcePolicy = enum {
    /// The source allows its content to be indexed and found.
    searchable,
    /// The source excluded itself from search — an incognito context, an app that
    /// declared no-index. Its content is never indexed.
    excluded,
};

/// An item offered to the indexer.
pub const Item = struct {
    sensitivity: Sensitivity,
    source: SourcePolicy,
};

/// Whether an item may be added to the index.
///
/// It is eligible only when it is ordinary and its source permits search. A secret
/// item is never indexed, and an item from an excluded source is never indexed, so
/// either classification alone keeps it out. The default for anything sensitive is
/// therefore exclusion, and only plainly ordinary, searchable content is admitted.
pub fn indexable(item: Item) bool {
    return item.sensitivity == .ordinary and item.source == .searchable;
}

test "ordinary searchable content is indexed" {
    try std.testing.expect(indexable(.{ .sensitivity = .ordinary, .source = .searchable }));
}

test "secret content is never indexed" {
    try std.testing.expect(!indexable(.{ .sensitivity = .secret, .source = .searchable }));
}

test "content from an excluded source is never indexed" {
    try std.testing.expect(!indexable(.{ .sensitivity = .ordinary, .source = .excluded }));
}

test "secret content from an excluded source is doubly excluded" {
    try std.testing.expect(!indexable(.{ .sensitivity = .secret, .source = .excluded }));
}

test "either classification alone keeps an item out, swept" {
    // The keep-secrets-out property: an indexed item is always both ordinary and
    // searchable; anything else is excluded.
    for (std.enums.values(Sensitivity)) |sensitivity| {
        for (std.enums.values(SourcePolicy)) |source| {
            const item: Item = .{ .sensitivity = sensitivity, .source = source };
            if (indexable(item)) {
                try std.testing.expectEqual(Sensitivity.ordinary, sensitivity);
                try std.testing.expectEqual(SourcePolicy.searchable, source);
            }
        }
    }
}
