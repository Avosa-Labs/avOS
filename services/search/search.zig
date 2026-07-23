//! Filtering search results to what the caller may actually see, so search never
//! becomes the side channel that reveals what direct access forbids.
//!
//! Search is a confused-deputy waiting to happen. The index sees everything on the
//! device — every file, message, and record — so that anything can be found; but a
//! given caller may read only some of it, and if search returns a match the caller
//! could not have opened directly, search has just disclosed it. The leak is subtle
//! because the result need not include the secret content: a title, a snippet, even
//! the mere existence of a matching document tells the caller something they were
//! not allowed to know. So a result is included only when the caller holds the
//! access the underlying item requires; everything else is omitted entirely, not
//! returned-but-blurred, because a blurred result still confirms the item exists.
//! Search is filtered by the same authority that governs direct access, so it can
//! never reveal more than that access would.
//!
//! This module searches nothing and ranks nothing. It filters a set of candidate
//! results to those the caller is authorized to see, as a pure function over each
//! result's required access and the access the caller holds.

const std = @import("std");

/// A candidate result from the index. Carries the access its underlying item
/// requires, so it can be filtered without opening the item.
pub const Result = struct {
    id: u64,
    /// The access scope the caller must hold to see this item at all — the same
    /// scope that governs opening it directly.
    required_scope: []const u8,
};

/// The access a caller holds: the set of scopes it may read.
pub const Access = struct {
    scopes: []const []const u8,

    /// Whether the caller holds a given scope.
    pub fn holds(access: Access, scope: []const u8) bool {
        for (access.scopes) |held| {
            if (std.mem.eql(u8, held, scope)) return true;
        }
        return false;
    }
};

/// Whether a caller may see a result: exactly when it holds the scope the result
/// requires. This is the same authority that governs direct access, so search
/// discloses nothing that opening the item would not.
pub fn visible(result: Result, access: Access) bool {
    return access.holds(result.required_scope);
}

/// Filters candidates to those the caller may see, writing them into `out` and
/// returning the visible slice.
///
/// A result the caller is not authorized for is omitted outright — not written to
/// the output at all — so its existence is never disclosed. The order of the
/// surviving results is preserved, and none is ever included without the caller
/// holding its required scope.
pub fn filter(candidates: []const Result, access: Access, out: []Result) []const Result {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (!visible(candidate, access)) continue;
        if (count >= out.len) break;
        out[count] = candidate;
        count += 1;
    }
    return out[0..count];
}

const catalog = [_]Result{
    .{ .id = 1, .required_scope = "personal.notes" },
    .{ .id = 2, .required_scope = "work.docs" },
    .{ .id = 3, .required_scope = "personal.notes" },
    .{ .id = 4, .required_scope = "secret.keys" },
};

test "a caller sees only results whose scope it holds" {
    const access: Access = .{ .scopes = &.{"personal.notes"} };
    var out: [8]Result = undefined;
    const results = filter(&catalog, access, &out);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
    try std.testing.expectEqual(@as(u64, 3), results[1].id);
}

test "a caller with multiple scopes sees the union" {
    const access: Access = .{ .scopes = &.{ "personal.notes", "work.docs" } };
    var out: [8]Result = undefined;
    const results = filter(&catalog, access, &out);
    try std.testing.expectEqual(@as(usize, 3), results.len);
}

test "a caller with no matching scope sees nothing" {
    const access: Access = .{ .scopes = &.{"other.stuff"} };
    var out: [8]Result = undefined;
    const results = filter(&catalog, access, &out);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "an unheld result is omitted entirely, not returned blurred" {
    // The existence-disclosure property: a secret the caller cannot access does not
    // appear in the output at all, so its existence is not confirmed.
    const access: Access = .{ .scopes = &.{"personal.notes"} };
    var out: [8]Result = undefined;
    const results = filter(&catalog, access, &out);
    for (results) |result| try std.testing.expect(result.id != 4); // the secret key
}

test "order is preserved among visible results" {
    const access: Access = .{ .scopes = &.{ "personal.notes", "secret.keys" } };
    var out: [8]Result = undefined;
    const results = filter(&catalog, access, &out);
    // ids 1, 3, 4 in their original order.
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
    try std.testing.expectEqual(@as(u64, 3), results[1].id);
    try std.testing.expectEqual(@as(u64, 4), results[2].id);
}

test "an empty access set sees nothing" {
    const access: Access = .{ .scopes = &.{} };
    var out: [8]Result = undefined;
    try std.testing.expectEqual(@as(usize, 0), filter(&catalog, access, &out).len);
}

test "every returned result is one the caller is authorized for, swept" {
    // The core property: whatever the caller's scopes, no result is ever returned
    // that the caller does not hold the scope for.
    const scope_sets = [_][]const []const u8{
        &.{"personal.notes"},
        &.{"work.docs"},
        &.{ "personal.notes", "work.docs", "secret.keys" },
        &.{},
    };
    for (scope_sets) |scopes| {
        const access: Access = .{ .scopes = scopes };
        var out: [8]Result = undefined;
        const results = filter(&catalog, access, &out);
        for (results) |result| try std.testing.expect(access.holds(result.required_scope));
    }
}
