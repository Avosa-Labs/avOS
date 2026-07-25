//! Deciding whether a developer feature is available, so the powerful tools stay firmly off for
//! an ordinary person and gated for a developer who has deliberately opted in.
//!
//! Developer features change what the device will run and reveal: inspecting internals,
//! sideloading, executing unsigned code. In everyday use none of that should exist, so every
//! developer feature is off unless developer mode has been explicitly enabled — the safe state
//! is the default, not something a person can wander into. Enabling developer mode is not
//! enough for the sharpest tools: sideloading and running unsigned code can hand the device to
//! untrusted software, so they additionally require a deliberate per-session confirmation, an
//! act that does not survive a restart. That way a moment's decision cannot leave the riskiest
//! doors standing open.
//!
//! This module enables nothing. It decides whether a developer feature is available, as a pure
//! function over developer-mode state and this session's confirmation.

const std = @import("std");

/// A developer feature, split by how much damage it can do if misused.
pub const Feature = enum {
    inspector,
    sideload,
    unsigned_code,
    verbose_logs,
    mock_location,
};

/// Whether a feature is dangerous enough to demand a per-session confirmation beyond merely
/// having developer mode on. Sideloading and unsigned code can run untrusted software, so they
/// alone carry this extra gate.
pub fn requiresConfirmation(feature: Feature) bool {
    return switch (feature) {
        .sideload, .unsigned_code => true,
        .inspector, .verbose_logs, .mock_location => false,
    };
}

/// Whether a developer feature is available right now.
///
/// Nothing is available unless developer mode is explicitly enabled, so the safe state is the
/// default. The dangerous features additionally require this session's confirmation, which does
/// not persist across a restart, so a one-time choice cannot leave them permanently open.
pub fn available(feature: Feature, enabled: bool, confirmed_this_session: bool) bool {
    if (!enabled) return false;
    if (requiresConfirmation(feature)) return confirmed_this_session;
    return true;
}

test "ordinary features are available once developer mode is enabled" {
    try std.testing.expect(available(.inspector, true, false));
    try std.testing.expect(available(.verbose_logs, true, false));
    try std.testing.expect(available(.mock_location, true, false));
}

test "dangerous features need this session's confirmation even in developer mode" {
    try std.testing.expect(!available(.sideload, true, false));
    try std.testing.expect(!available(.unsigned_code, true, false));
    try std.testing.expect(available(.sideload, true, true));
    try std.testing.expect(available(.unsigned_code, true, true));
}

test "confirmation alone grants nothing without developer mode" {
    try std.testing.expect(!available(.sideload, false, true));
    try std.testing.expect(!available(.inspector, false, true));
}

test "with developer mode disabled nothing is available, swept" {
    // The safe-default property: no feature is available while developer mode is off, whatever
    // the session confirmation happens to be.
    for (std.enums.values(Feature)) |feature| {
        for ([_]bool{ false, true }) |confirmed| {
            try std.testing.expect(!available(feature, false, confirmed));
        }
    }
}
