//! The shared shape of an app's human door: the token-styled rows a surface lays out,
//! so every app's surface renders from the one design source and reads as one system.
//!
//! A surface is the person's way into an app's one domain — the header that names it, a
//! line of its current state, and a row for each thing the person can do, which are the
//! same capabilities an agent discovers. What matters for coherence is that all of it is
//! styled from the design tokens and nothing else: a header in the primary text colour, a
//! status line muted, an ordinary action in the accent, a consequential action in the
//! caution hue so a person sees which taps will reach outside or move value. Because
//! those are the only colours a row can carry and each is a resolved token, a surface is
//! design-conformant by construction, and a test pins it. Building every app's surface on
//! this one helper is what keeps nine apps looking like one operating system rather than
//! nine.
//!
//! This module lays out rows; it draws no pixels. The pixels are the shell's, over the
//! rows a surface produces.

const std = @import("std");
const design = @import("design");

const theme = design.theme;
pub const Colour = theme.Colour;

/// What a row is: the app's name, a line of its state, or an action the person can take.
pub const RowKind = enum { header, status, action, action_consequential };

/// One laid-out row: its text, what kind it is, and the resolved token colour it draws
/// in.
pub const Row = struct {
    label: []const u8,
    kind: RowKind,
    colour: Colour,
};

/// A pane header naming the app, in the primary text colour.
pub fn header(label: []const u8) Row {
    return .{ .label = label, .kind = .header, .colour = theme.screen_text };
}

/// A status line — a count, a summary — in the muted secondary colour.
pub fn status(label: []const u8) Row {
    return .{ .label = label, .kind = .status, .colour = theme.screen_text_muted };
}

/// An action the person can take. A consequential action — one held for the person when
/// an agent proposes it — is drawn in the caution hue so it reads as weightier than an
/// ordinary one.
pub fn action(label: []const u8, consequential: bool) Row {
    return if (consequential)
        .{ .label = label, .kind = .action_consequential, .colour = theme.amber }
    else
        .{ .label = label, .kind = .action, .colour = theme.agent };
}

/// Whether a colour is one of the surface's four resolved design tokens — the design
/// conformance every surface's rows must satisfy.
pub fn isToken(colour: Colour) bool {
    return std.meta.eql(colour, theme.screen_text) or
        std.meta.eql(colour, theme.screen_text_muted) or
        std.meta.eql(colour, theme.agent) or
        std.meta.eql(colour, theme.amber);
}

/// The imports a `Tool` carries that a surface needs: its display name and whether it is
/// consequential. Kept structural so a surface does not depend on the tool registry's
/// full type.
pub const ActionSpec = struct {
    name: []const u8,
    consequential: bool,
};

/// Lays out a standard app surface: a header, a status line, and a row per action.
/// Returns the filled prefix of `buffer`.
pub fn layout(app_name: []const u8, state_summary: []const u8, actions: []const ActionSpec, buffer: []Row) []const Row {
    var count: usize = 0;
    if (count < buffer.len) {
        buffer[count] = header(app_name);
        count += 1;
    }
    if (count < buffer.len) {
        buffer[count] = status(state_summary);
        count += 1;
    }
    for (actions) |spec| {
        if (count >= buffer.len) break;
        buffer[count] = action(spec.name, spec.consequential);
        count += 1;
    }
    return buffer[0..count];
}

/// Confirms every row a surface produced uses a resolved design token — the frame
/// conformance check a surface's tests call.
pub fn allTokens(rows: []const Row) bool {
    for (rows) |row| {
        if (!isToken(row.colour)) return false;
    }
    return true;
}

// --- Tests ---

const testing = std.testing;

test "a laid-out surface has a header, a status line, and a row per action" {
    const actions = [_]ActionSpec{
        .{ .name = "read", .consequential = false },
        .{ .name = "send", .consequential = true },
    };
    var buffer: [8]Row = undefined;
    const rows = layout("Sample", "2 items", &actions, &buffer);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqual(RowKind.header, rows[0].kind);
    try testing.expectEqual(RowKind.status, rows[1].kind);
    // The consequential action is marked and drawn in the caution hue.
    try testing.expectEqual(RowKind.action_consequential, rows[3].kind);
}

test "every colour a surface can produce is a resolved design token" {
    const actions = [_]ActionSpec{.{ .name = "x", .consequential = false }};
    var buffer: [8]Row = undefined;
    const rows = layout("Sample", "0", &actions, &buffer);
    try testing.expect(allTokens(rows));
}
