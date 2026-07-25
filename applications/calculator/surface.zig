//! The Calculator surface: the human door onto the calculator — a header, a ready line,
//! and its one capability, laid out from the design tokens over the shared helper.
//!
//! The calculator holds no private state and reaches nothing outside, so its surface is
//! the simplest: it names the app, shows it is ready, and offers its evaluate action.
//! Every colour is a resolved design token.

const std = @import("std");
const surface = @import("../framework/surface.zig");
const app = @import("calculator.zig");

pub const Row = surface.Row;

/// Renders the Calculator surface into `buffer`.
pub fn render(buffer: []Row) []const Row {
    var actions: [app.tools.len]surface.ActionSpec = undefined;
    inline for (app.tools, 0..) |tool, i| {
        actions[i] = .{ .name = tool.name, .consequential = tool.effect.needsApproval() };
    }
    return surface.layout("Calculator", "Ready", &actions, buffer);
}

const testing = std.testing;

test "the calculator surface renders a header, a ready line, and its action" {
    var buffer: [8]Row = undefined;
    const rows = render(&buffer);
    try testing.expectEqual(@as(usize, 2 + app.tools.len), rows.len);
    try testing.expect(surface.allTokens(rows));
}
