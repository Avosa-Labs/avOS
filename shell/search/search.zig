//! Deciding which search results a query may reach and whether each is shown given the lock,
//! so global search is instantly useful without letting a locked device leak private data.
//!
//! Global search reaches across the whole device, and that reach is exactly what makes the lock
//! matter here. A locked phone is one a stranger may be holding, so search must answer without
//! becoming a window into the person's life. Public app entries — launching an app, a settings
//! toggle — reveal nothing private and may show while locked, keeping search useful at a glance.
//! Personal data and secrets stay behind the lock and appear only after the person unlocks,
//! because the lock exists precisely to gate them. Among the results that do show, relevance is
//! a separate, pure ranking that never widens what is visible.
//!
//! This module searches nothing. It decides which results are visible and how relevant they are,
//! as a pure function over each result's sensitivity, the lock state, and match signals.

const std = @import("std");

/// How private a search result is, which decides whether it may show on a locked device.
pub const Sensitivity = enum {
    /// An app launch, a settings pane, a public place — reveals nothing private.
    public_app,
    /// The person's own content: messages, notes, contacts.
    personal_data,
    /// Credentials and other secrets that must never appear casually.
    secret,
};

/// Whether a result of the given sensitivity is shown given the lock state.
///
/// Unlocked, everything the person searches is theirs to see. Locked, only public app entries
/// show — personal data and secrets require unlocking, because a locked device may be in
/// someone else's hands and the lock is what keeps those private.
pub fn visible(sensitivity: Sensitivity, locked: bool) bool {
    if (!locked) return true;
    return sensitivity == .public_app;
}

/// A relevance score for ordering results; a higher score is more relevant.
///
/// An exact name match dominates, then apps outrank other kinds, and recency breaks the
/// remaining ties. Ranking only orders what is already visible; it can never make a hidden
/// result appear. The score is layered so each signal strictly outweighs the ones below it.
pub fn rank(exact_name_match: bool, is_app: bool, recency: u64) u128 {
    const exact_bit: u128 = if (exact_name_match) 1 << 65 else 0;
    const app_bit: u128 = if (is_app) 1 << 64 else 0;
    return exact_bit | app_bit | recency;
}

test "public app entries show while locked" {
    try std.testing.expect(visible(.public_app, true));
}

test "personal and secret results require unlock" {
    try std.testing.expect(!visible(.personal_data, true));
    try std.testing.expect(!visible(.secret, true));
    try std.testing.expect(visible(.personal_data, false));
}

test "an exact name match outranks an app which outranks by recency" {
    try std.testing.expect(rank(true, false, 0) > rank(false, true, 999));
    try std.testing.expect(rank(false, true, 0) > rank(false, false, 999));
    try std.testing.expect(rank(false, false, 5) > rank(false, false, 4));
}

test "no personal or secret result is ever visible while locked, swept" {
    // The lock-integrity property: while locked, only public app entries can be seen.
    for (std.enums.values(Sensitivity)) |s| {
        if (visible(s, true)) try std.testing.expectEqual(Sensitivity.public_app, s);
    }
}
