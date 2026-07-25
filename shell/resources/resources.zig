//! Deciding which resource consumers are surfaced to the person and in what order, so the
//! battery/storage/network view stays a short, honest list of what actually matters.
//!
//! A resource view that lists every consumer is noise: dozens of processes each using a sliver
//! tell the person nothing. So a consumer is surfaced only once its share crosses a small
//! notability threshold, keeping the list short enough to read at a glance. Ranking then puts
//! the biggest draw on top — but at an equal share a background consumer outranks a foreground
//! one, because a person already knows the app in front of them is working; the surprising
//! drain, the thing running unseen, is precisely what the view exists to reveal.
//!
//! This module surfaces nothing. It decides which consumers are notable and how they rank, as
//! a pure function over each consumer's share and foreground state.

const std = @import("std");

/// A single draw on a resource, described by only what the ranking decision needs.
pub const Consumer = struct {
    /// What is doing the consuming, kept for display; it does not affect the decision.
    kind: enum { app, agent, system },
    /// Share of the resource in parts-per-thousand, so sub-percent draws can be compared.
    share_permille: u16,
    /// Whether this is the thing the person is actively looking at right now.
    is_foreground: bool,
};

/// A consumer must use at least this share (parts-per-thousand) before it is worth showing.
/// Below it the draw is noise, and surfacing it would only lengthen the list.
pub const notability_permille: u16 = 20;

/// Whether a consumer is worth surfacing at all.
///
/// Only a consumer above the small notability threshold is shown, so the list stays short and
/// every row on it is a draw large enough to be worth a person's attention.
pub fn notable(consumer: Consumer) bool {
    return consumer.share_permille >= notability_permille;
}

/// Whether `a` should rank above `b` in the surfaced list.
///
/// A larger share ranks higher. At an equal share the background consumer ranks above the
/// foreground one, because unexpected drain from something the person is not watching is the
/// information the view is meant to reveal.
pub fn heavier(a: Consumer, b: Consumer) bool {
    if (a.share_permille != b.share_permille) return a.share_permille > b.share_permille;
    return !a.is_foreground and b.is_foreground;
}

test "only consumers above the threshold are notable" {
    try std.testing.expect(notable(.{ .kind = .app, .share_permille = 200, .is_foreground = true }));
    try std.testing.expect(!notable(.{ .kind = .system, .share_permille = 5, .is_foreground = false }));
}

test "a consumer exactly at the threshold is notable" {
    try std.testing.expect(notable(.{ .kind = .agent, .share_permille = notability_permille, .is_foreground = false }));
}

test "a larger share ranks higher" {
    const big: Consumer = .{ .kind = .app, .share_permille = 300, .is_foreground = true };
    const small: Consumer = .{ .kind = .app, .share_permille = 100, .is_foreground = true };
    try std.testing.expect(heavier(big, small));
    try std.testing.expect(!heavier(small, big));
}

test "at equal share the background drain ranks above the foreground app" {
    const background: Consumer = .{ .kind = .agent, .share_permille = 150, .is_foreground = false };
    const foreground: Consumer = .{ .kind = .app, .share_permille = 150, .is_foreground = true };
    try std.testing.expect(heavier(background, foreground));
    try std.testing.expect(!heavier(foreground, background));
}

test "a consumer below the notability threshold is never surfaced, swept" {
    // The short-list property: nothing under the threshold is ever notable, at any foreground
    // state, so the list can only ever contain draws worth reading.
    var share: u16 = 0;
    while (share < notability_permille) : (share += 1) {
        try std.testing.expect(!notable(.{ .kind = .app, .share_permille = share, .is_foreground = true }));
        try std.testing.expect(!notable(.{ .kind = .system, .share_permille = share, .is_foreground = false }));
    }
}
