//! Resolving an SDK design-token name to the platform's canonical token, so an app built with the
//! SDK uses the same design values the system does and follows a theme change automatically.
//!
//! The SDK exposes design tokens — semantic names like "surface" or "accent" — that an app uses
//! instead of hard-coding colours and spacings. The whole point is that these names resolve to the
//! platform's own canonical tokens, so an app's surface colour is the system's surface colour, and
//! when the person changes the theme or the platform updates its palette, every app that used the
//! token follows without a code change. That only holds if the SDK's token set is a closed reference
//! to the platform's, not a private copy: a name in the SDK either maps to a real platform token or
//! it does not resolve, so an app cannot invent a token that drifts from the system, and a token the
//! platform renames is a deliberate SDK update rather than a silent divergence. Resolving names
//! against a closed reference is what keeps SDK-built apps visually part of the system rather than
//! lookalikes that fall out of sync.
//!
//! This module renders nothing. It resolves an SDK token name to its canonical platform token, from
//! a closed reference, as a pure function.

const std = @import("std");

/// One entry mapping an SDK token name to the platform's canonical token identifier.
const Entry = struct {
    name: []const u8,
    canonical: []const u8,
};

/// The closed reference set. An SDK token name absent from it does not resolve, so an app cannot use
/// a token the platform does not define.
const reference = [_]Entry{
    .{ .name = "surface", .canonical = "platform.color.surface" },
    .{ .name = "on-surface", .canonical = "platform.color.on-surface" },
    .{ .name = "accent", .canonical = "platform.color.accent" },
    .{ .name = "spacing-unit", .canonical = "platform.metric.spacing" },
};

/// Resolves an SDK token name to its canonical platform token, or null if the name is not a defined
/// token.
pub fn resolve(name: []const u8) ?[]const u8 {
    for (reference) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.canonical;
    }
    return null;
}

/// Whether a name is a defined SDK token.
pub fn has(name: []const u8) bool {
    return resolve(name) != null;
}

test "a defined token resolves to the platform canonical" {
    try std.testing.expectEqualStrings("platform.color.surface", resolve("surface").?);
    try std.testing.expectEqualStrings("platform.color.accent", resolve("accent").?);
}

test "an undefined token does not resolve" {
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("made-up-token"));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve(""));
}

test "the same name always resolves to the same canonical" {
    try std.testing.expectEqualStrings(resolve("surface").?, resolve("surface").?);
}

test "every reference token resolves and nothing else does, swept" {
    for (reference) |entry| {
        try std.testing.expect(has(entry.name));
        try std.testing.expectEqualStrings(entry.canonical, resolve(entry.name).?);
    }
    try std.testing.expect(!has("not.a.token"));
}
