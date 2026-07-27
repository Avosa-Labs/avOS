//! The Agents surface: the human door onto the flagship — a header, a status line, and its actions,
//! laid out from the design tokens over the shared helper. Every colour is a resolved token.

const std = @import("std");
const surface = @import("../framework/surface.zig");
const app = @import("agents.zig");

pub const Row = surface.Row;

/// Renders the Agents surface into `buffer`.
pub fn render(buffer: []Row) []const Row {
    var actions: [app.tools.len]surface.ActionSpec = undefined;
    inline for (app.tools, 0..) |tool, i| {
        actions[i] = .{ .name = tool.name, .consequential = tool.effect.needsApproval() };
    }
    return surface.layout("Agents", "Watching", &actions, buffer);
}

const testing = std.testing;

test "the agents surface renders a header, a status line, and its actions" {
    var buffer: [8]Row = undefined;
    const rows = render(&buffer);
    try testing.expectEqual(@as(usize, 2 + app.tools.len), rows.len);
    try testing.expect(surface.allTokens(rows));
}
