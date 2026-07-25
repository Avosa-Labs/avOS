//! The Calendar surface: the human door onto the app's one domain — a header, a line of
//! its real state, and a row for each thing the person can do, laid out from the design
//! tokens over the shared surface helper.
//!
//! A person reaches Calendar here; an agent reaches the same domain through its
//! capabilities. This surface reads the real store and renders it: the current count of
//! its content, and a row per capability the person can tap, with a consequential one
//! marked in the caution hue. Every colour is a resolved design token, pinned by the
//! conformance test.
//!
//! This module lays out rows; the pixels are the shell's.

const std = @import("std");
const surface = @import("../framework/surface.zig");
const app = @import("calendar.zig");

pub const Row = surface.Row;

/// Renders the Calendar surface from the real store into `buffer`. `scratch` holds the
/// formatted state line the returned rows borrow.
pub fn render(store: *const app.Store, scratch: []u8, buffer: []Row) []const Row {
    var actions: [app.tools.len]surface.ActionSpec = undefined;
    inline for (app.tools, 0..) |tool, i| {
        actions[i] = .{ .name = tool.name, .consequential = tool.effect.needsApproval() };
    }
    const summary = std.fmt.bufPrint(scratch, "{d} events", .{store.count()}) catch "";
    return surface.layout("Calendar", summary, &actions, buffer);
}

const testing = std.testing;

test "the surface renders a header, a real state line, and a row per capability" {
    const gpa = testing.allocator;
    var store = app.Store.init(gpa);
    defer store.deinit();
    var scratch: [24]u8 = undefined;
    var buffer: [16]Row = undefined;
    const rows = render(&store, &scratch, &buffer);
    try testing.expectEqual(@as(usize, 2 + app.tools.len), rows.len);
    try testing.expectEqual(surface.RowKind.header, rows[0].kind);
}

test "every colour the surface uses is a resolved design token" {
    const gpa = testing.allocator;
    var store = app.Store.init(gpa);
    defer store.deinit();
    var scratch: [24]u8 = undefined;
    var buffer: [16]Row = undefined;
    try testing.expect(surface.allTokens(render(&store, &scratch, &buffer)));
}
