//! The reviewed binding from the reference design's colours to token roles.
//!
//! The extractor emits every colour the design states; this file records what each one
//! *means* — which token role it fills — so conformance is enumerable rather than
//! asserted. A design colour is either mapped to a token role here, or listed as a
//! justified exception (a gradient stop, a shadow tint, a scrim) with a reason and an
//! expiry or a task. A colour that is neither mapped nor justified fails the conformance
//! gate: "map or justify", so the "100% conformant" claim is something you can read down
//! the list and check, not a slogan.
//!
//! Ownership: this map is a design artifact, not a code convenience. Changing a mapping —
//! rebinding a colour to a different role, or adding a justification — is a **design
//! decision** that requires design-owner approval in review, not merely a passing build.
//! Every justification carries an expiry or a linked task, so "justify" cannot quietly
//! become "justify everything": an exception is a debt with a due date, and the gate
//! surfaces an expired one.
//!
//! The token level of the conformance gate lives here as a test: for every mapping, the
//! resolved reference token must equal the design colour it is bound to, in linear light.
//! Drift at the source of truth — a token edited away from the design — fails immediately.

const std = @import("std");
const theme = @import("../theme/theme.zig");

/// A design colour bound to a token role. `colour` is the resolved reference token, so the
/// test below compares the token the renderer actually paints against the design's value.
pub const Mapping = struct {
    hex: []const u8,
    role: []const u8,
    colour: theme.Colour,
};

/// Every design colour that carries meaning, bound to the token role it fills. Reviewed
/// by the design owner; a change here is a design change.
pub const mappings = [_]Mapping{
    .{ .hex = "9a6cff", .role = "agent", .colour = theme.agent },
    .{ .hex = "7c78ff", .role = "agent_soft", .colour = theme.agent_soft },
    .{ .hex = "5aa8ff", .role = "human", .colour = theme.human },
    .{ .hex = "37c2a6", .role = "teal", .colour = theme.teal },
    .{ .hex = "5fe0b0", .role = "teal_bright", .colour = theme.teal_bright },
    .{ .hex = "ff8f6b", .role = "coral", .colour = theme.coral },
    .{ .hex = "ffb15c", .role = "amber", .colour = theme.amber },
    .{ .hex = "e46a6a", .role = "denied", .colour = theme.denied },
    .{ .hex = "a774ff", .role = "app_principal", .colour = theme.app_principal },
    .{ .hex = "c86ff0", .role = "session_principal", .colour = theme.session_principal },
    .{ .hex = "0b0a11", .role = "base", .colour = theme.base },
    .{ .hex = "241f30", .role = "panel", .colour = theme.panel },
    .{ .hex = "2a2833", .role = "surface", .colour = theme.surface },
    .{ .hex = "322c40", .role = "surface_raised", .colour = theme.surface_raised },
    .{ .hex = "f4f5f7", .role = "text_primary", .colour = theme.text_primary },
    .{ .hex = "948fa2", .role = "text_secondary", .colour = theme.text_secondary },
    .{ .hex = "6a6478", .role = "text_tertiary", .colour = theme.text_tertiary },
};

/// A design colour deliberately not bound to a token role, with why and when it is revisited.
/// A justification is a debt: it carries an expiry date or a linked task, never neither.
pub const Justification = struct {
    hex: []const u8,
    reason: []const u8,
    /// Either an ISO date the exception must be revisited by, or a task reference — one is
    /// required, so an exception cannot live forever unexamined.
    until: []const u8,
};

pub const justifications = [_]Justification{
    .{ .hex = "ffffff", .reason = "pure white — screen card fills and on-accent text, not a semantic accent", .until = "task:tokenize-neutrals" },
    .{ .hex = "000000", .reason = "pure black — shadow base, consumed by the elevation effect, not painted directly", .until = "task:tokenize-neutrals" },
    .{ .hex = "39b7e6", .reason = "icon gradient stop (health/weather) — decorative, lives in the icon gradient tokens", .until = "task:map-icon-gradients" },
    .{ .hex = "6f8bff", .reason = "icon gradient stop (messages/mail) — decorative gradient token", .until = "task:map-icon-gradients" },
    .{ .hex = "4a8cff", .reason = "icon gradient stop (messages) — decorative gradient token", .until = "task:map-icon-gradients" },
    .{ .hex = "4b3a66", .reason = "shadow tint — an elevation shadow colour, consumed by the effect layer", .until = "task:tokenize-elevation" },
    .{ .hex = "3a3a55", .reason = "hairline/border tint (often with alpha) — a divider role pending a token", .until = "task:tokenize-dividers" },
    .{ .hex = "4a4658", .reason = "border/divider tint — pending a divider token", .until = "task:tokenize-dividers" },
    .{ .hex = "8a8694", .reason = "muted label variant — near text_secondary; pending a dim-label token", .until = "task:tokenize-labels" },
    .{ .hex = "37a684", .reason = "teal pressed/darker state — pending an interaction-state token", .until = "task:tokenize-states" },
};

// --- The token level of the conformance gate ---

/// sRGB 8-bit channel to linear light, matching the extractor's conversion so the two
/// sides of the comparison are computed the same way.
fn srgbToLinear(channel: u8) f64 {
    const c = @as(f64, @floatFromInt(channel)) / 255.0;
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn hexNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => 0,
    };
}

fn hexByte(hex: []const u8, index: usize) u8 {
    return hexNibble(hex[index]) * 16 + hexNibble(hex[index + 1]);
}

const testing = std.testing;

test "every mapped token equals the design colour it is bound to, in linear light" {
    // Drift catcher: if a token is edited away from the design's value, its linear-light
    // channels diverge from the mapped hex and this fails at the source of truth.
    for (mappings) |mapping| {
        try testing.expect(mapping.hex.len == 6); // rrggbb
        const design_r = srgbToLinear(hexByte(mapping.hex, 0));
        const design_g = srgbToLinear(hexByte(mapping.hex, 2));
        const design_b = srgbToLinear(hexByte(mapping.hex, 4));
        const token_r = srgbToLinear(mapping.colour.red);
        const token_g = srgbToLinear(mapping.colour.green);
        const token_b = srgbToLinear(mapping.colour.blue);
        try testing.expect(@abs(design_r - token_r) < 1e-9);
        try testing.expect(@abs(design_g - token_g) < 1e-9);
        try testing.expect(@abs(design_b - token_b) < 1e-9);
    }
}

test "every justification carries an expiry or a task, never neither" {
    // "map or justify" cannot rot into "justify everything": each exception is a debt with
    // a due date (an ISO date) or a linked task.
    for (justifications) |j| {
        try testing.expect(j.reason.len > 0);
        try testing.expect(j.until.len > 0);
        const dated = std.mem.startsWith(u8, j.until, "20"); // an ISO date like 2026-...
        const tasked = std.mem.startsWith(u8, j.until, "task:");
        try testing.expect(dated or tasked);
    }
}

test "no colour is both mapped and justified" {
    for (mappings) |mapping| {
        for (justifications) |j| {
            try testing.expect(!std.mem.eql(u8, mapping.hex, j.hex));
        }
    }
}
