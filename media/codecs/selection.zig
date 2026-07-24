//! Choosing a codec both sides support, from a preference order, so media plays in the best
//! available format and an unsupported stream is refused rather than played as noise.
//!
//! Two devices negotiating media each support a set of codecs, and they must agree on one or
//! nothing plays. The choice is a preference order intersected with capability: the receiver
//! prefers codecs in a ranked order — the most efficient or highest-quality first — and picks
//! the highest-ranked one the sender also offers. This gives the best format both can handle
//! rather than the first that happens to match. When there is no overlap at all — the sender
//! offers only formats the receiver cannot decode — the honest outcome is to refuse, because
//! attempting to decode an unsupported stream produces noise or a crash, and a clear "cannot
//! play this format" is better than either. So codec selection is an intersection under a
//! preference order, defaulting to refusal when the sets do not meet, which is what keeps media
//! playing well when it can and failing cleanly when it cannot.
//!
//! This module decodes nothing. It selects the preferred codec both sides support, or refuses,
//! as a pure function over the preference order and the offered set.

const std = @import("std");

/// The result of codec negotiation.
pub const Selection = union(enum) {
    /// The chosen codec name, the highest-ranked one both sides support.
    codec: []const u8,
    /// No codec is supported by both sides; the stream cannot be played.
    unsupported,

    pub fn selected(selection: Selection) bool {
        return selection == .codec;
    }
};

/// Whether an offered set contains a codec.
fn offers(offered: []const []const u8, codec: []const u8) bool {
    for (offered) |name| {
        if (std.mem.eql(u8, name, codec)) return true;
    }
    return false;
}

/// Selects the preferred codec both sides support.
///
/// The receiver's preference order is walked from most to least preferred, and the first codec
/// the sender also offers is chosen, so the result is the best format both can handle rather
/// than an arbitrary match. If no preferred codec is offered, the stream is unsupported and
/// refused, because playing a format the receiver cannot decode produces noise rather than
/// media.
pub fn select(preference_order: []const []const u8, offered: []const []const u8) Selection {
    for (preference_order) |preferred| {
        if (offers(offered, preferred)) return .{ .codec = preferred };
    }
    return .unsupported;
}

const preference = [_][]const u8{ "av1", "hevc", "h264" };

test "the most preferred mutually-supported codec is chosen" {
    const offered = [_][]const u8{ "h264", "hevc" };
    switch (select(&preference, &offered)) {
        .codec => |name| try std.testing.expectEqualStrings("hevc", name), // hevc outranks h264
        .unsupported => return error.TestUnexpectedResult,
    }
}

test "the top preference wins when offered" {
    const offered = [_][]const u8{ "av1", "h264" };
    switch (select(&preference, &offered)) {
        .codec => |name| try std.testing.expectEqualStrings("av1", name),
        .unsupported => return error.TestUnexpectedResult,
    }
}

test "a single overlapping codec is chosen" {
    const offered = [_][]const u8{"h264"};
    switch (select(&preference, &offered)) {
        .codec => |name| try std.testing.expectEqualStrings("h264", name),
        .unsupported => return error.TestUnexpectedResult,
    }
}

test "no overlap is unsupported" {
    const offered = [_][]const u8{ "vp8", "theora" };
    try std.testing.expectEqual(Selection.unsupported, select(&preference, &offered));
}

test "an empty offer is unsupported" {
    try std.testing.expectEqual(Selection.unsupported, select(&preference, &.{}));
}

test "a selected codec is always in both sets and highest-ranked, swept" {
    // The best-mutual property: whenever a codec is selected, it is offered and no
    // higher-ranked preference was also offered.
    const offer_sets = [_][]const []const u8{
        &.{ "h264", "hevc", "av1" },
        &.{ "h264", "hevc" },
        &.{"h264"},
        &.{"vp8"},
    };
    for (offer_sets) |offered| {
        switch (select(&preference, offered)) {
            .codec => |chosen| {
                try std.testing.expect(offers(offered, chosen));
                // No higher preference is offered.
                for (preference) |pref| {
                    if (std.mem.eql(u8, pref, chosen)) break;
                    try std.testing.expect(!offers(offered, pref));
                }
            },
            .unsupported => {},
        }
    }
}
