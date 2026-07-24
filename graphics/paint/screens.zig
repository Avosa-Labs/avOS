//! The agent-native shell screens, composed into rendered frames.
//!
//! These are the surfaces the tour walks through after home: the approval that holds a consequential
//! action, the activity ledger that records who acted under which capability, and the principals
//! inspector that shows humans and agents as first-class citizens. Each is built the same way the home
//! screen is — a plain composition of paint calls over a framebuffer, no decisions — so each frame is
//! deterministic and diffable. They share a wallpaper, a status bar, and a header, so the shell reads as
//! one coherent surface rather than a set of unrelated screens. The content here is fixed demonstration
//! material; later the same layouts are driven from live control-plane state.
//!
//! Rendered portrait at a phone's proportions, matching the home screen.

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

pub const width: u32 = 390;
pub const height: u32 = 844;

/// The shell screens this module can render.
pub const Screen = enum { approval, ledger, principals };

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

pub fn render(target: *Framebuffer, screen: Screen) void {
    wallpaper(target);
    statusBar(target);
    switch (screen) {
        .approval => renderApproval(target),
        .ledger => renderLedger(target),
        .principals => renderPrincipals(target),
    }
}

// --- Shared chrome ---

fn wallpaper(target: *Framebuffer) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
}

fn statusBar(target: *Framebuffer) void {
    _ = text.draw(target, 24, 40, "9:41", 16, s(theme.text_primary));
    var indicator: u8 = 0;
    while (indicator < 3) : (indicator += 1) {
        vector.fillDisc(target, @floatFromInt(width - 24 - @as(u32, indicator) * 12), 34, 3, s(theme.text_secondary));
    }
}

fn header(target: *Framebuffer, title: []const u8, subtitle: []const u8) void {
    _ = text.draw(target, 24, 100, title, 24, s(theme.text_primary));
    _ = text.draw(target, 24, 126, subtitle, 13, s(theme.text_secondary));
}

/// A rounded card surface.
fn card(target: *Framebuffer, rect: Rect, colour: theme.Colour) void {
    paint.paint(target, &.{.{ .rounded = .{ .rect = rect, .radius = theme.radius_lg, .colour = s(colour) } }});
}

/// A pill button with centred text; `filled` paints it in the accent, otherwise a surface.
fn button(target: *Framebuffer, rect: Rect, label: []const u8, filled: bool, accent: theme.Colour) void {
    const bg = if (filled) accent else theme.surface_raised;
    paint.paint(target, &.{.{ .rounded = .{ .rect = rect, .radius = theme.radius_pill, .colour = s(bg) } }});
    const fg = if (filled) theme.base else theme.text_primary;
    const cx = @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w)) / 2.0;
    const by = @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) / 2.0 + 5.0;
    text.drawCentred(target, cx, by, label, 14, s(fg));
}

/// A coloured principal dot at (cx,cy).
fn dot(target: *Framebuffer, cx: f32, cy: f32, colour: theme.Colour) void {
    vector.fillDisc(target, cx, cy, 6, s(colour));
}

// --- Approval ---

fn renderApproval(target: *Framebuffer) void {
    header(target, "Approval", "Nothing consequential happens silently");

    const c: Rect = .{ .x = 20, .y = 200, .w = width - 40, .h = 380 };
    card(target, c, theme.surface);

    // Requesting agent.
    dot(target, 46, 246, theme.agent);
    _ = text.draw(target, 62, 251, "Travel agent wants to", 13, s(theme.text_secondary));

    _ = text.draw(target, 40, 300, "Pay hotel deposit", 22, s(theme.text_primary));
    const amount_end = text.draw(target, 40, 348, "420.00", 36, s(theme.coral));
    _ = text.draw(target, amount_end + 8, 344, "EUR", 15, s(theme.text_secondary));

    line(target, 40, 384, (width - 40));
    field(target, 404, "Capability", "payments.charge");
    field(target, 440, "To", "Hotel, Lisbon");
    field(target, 476, "Once", "Cannot repeat");

    // Buttons.
    button(target, .{ .x = 40, .y = 520, .w = 150, .h = 44 }, "Deny", false, theme.agent);
    button(target, .{ .x = 200, .y = 520, .w = 150, .h = 44 }, "Approve", true, theme.agent);

    _ = text.draw(target, 24, 620, "Nothing spends without you.", 13, s(theme.text_secondary));
}

fn field(target: *Framebuffer, y: i32, key: []const u8, value: []const u8) void {
    const fy: f32 = @floatFromInt(y);
    _ = text.draw(target, 40, fy, key, 13, s(theme.text_secondary));
    _ = text.draw(target, 180, fy, value, 13, s(theme.text_primary));
}

/// The x at which right-aligned text of the given width ends `right_margin` from the frame's right edge.
fn rightAlign(str: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(width)) - 40.0 - text.measure(str, size);
}

fn line(target: *Framebuffer, x0: i32, y: i32, x1: i32) void {
    vector.strokePolyline(target, &.{ .{ .x = @floatFromInt(x0), .y = @floatFromInt(y) }, .{ .x = @floatFromInt(x1), .y = @floatFromInt(y) } }, 1, s(theme.divider), false);
}

// --- Activity ledger ---

const LedgerRow = struct { actor: []const u8, action: []const u8, capability: []const u8, outcome: []const u8, colour: theme.Colour, denied: bool };

const ledger_rows = [_]LedgerRow{
    .{ .actor = "Planner", .action = "read calendar", .capability = "calendar.read", .outcome = "ok", .colour = theme.agent, .denied = false },
    .{ .actor = "You", .action = "approved a payment", .capability = "payments", .outcome = "once", .colour = theme.human, .denied = false },
    .{ .actor = "Travel agent", .action = "confirm venue", .capability = "network.call", .outcome = "approved", .colour = theme.agent, .denied = false },
    .{ .actor = "Docs agent", .action = "read mail", .capability = "mail.read", .outcome = "denied", .colour = theme.denied, .denied = true },
    .{ .actor = "Planner", .action = "arrange focus", .capability = "calendar.write", .outcome = "ok", .colour = theme.agent, .denied = false },
};

fn renderLedger(target: *Framebuffer) void {
    header(target, "Activity", "Who acted, under which capability");

    // Filter chips.
    chip(target, .{ .x = 24, .y = 150, .w = 60, .h = 30 }, "All", true);
    chip(target, .{ .x = 92, .y = 150, .w = 84, .h = 30 }, "Agents", false);
    chip(target, .{ .x = 184, .y = 150, .w = 80, .h = 30 }, "Denied", false);

    var y: i32 = 200;
    for (ledger_rows) |r| {
        const c: Rect = .{ .x = 20, .y = y, .w = width - 40, .h = 64 };
        card(target, c, if (r.denied) theme.surface else theme.surface);
        dot(target, 44, @floatFromInt(y + 24), r.colour);
        _ = text.draw(target, 62, @floatFromInt(y + 28), r.actor, 14, s(theme.text_primary));
        _ = text.draw(target, 62, @floatFromInt(y + 50), r.action, 12, s(theme.text_secondary));
        // Outcome badge on the right.
        const badge_colour = if (r.denied) theme.denied else theme.teal;
        _ = text.draw(target, rightAlign(r.outcome, 12), @floatFromInt(y + 28), r.outcome, 12, s(badge_colour));
        _ = text.draw(target, rightAlign(r.capability, 11), @floatFromInt(y + 50), r.capability, 11, s(theme.text_tertiary));
        y += 74;
    }

    _ = text.draw(target, 24, @floatFromInt(y + 22), "Every action, signed and exportable.", 12, s(theme.text_secondary));
}

fn chip(target: *Framebuffer, rect: Rect, label: []const u8, active: bool) void {
    const bg = if (active) theme.agent else theme.surface;
    paint.paint(target, &.{.{ .rounded = .{ .rect = rect, .radius = theme.radius_pill, .colour = s(bg) } }});
    const fg = if (active) theme.base else theme.text_secondary;
    const cx = @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w)) / 2.0;
    text.drawCentred(target, cx, @as(f32, @floatFromInt(rect.y)) + 20.0, label, 12, s(fg));
}

// --- Principals ---

const Principal = struct { kind: []const u8, name: []const u8, role: []const u8, colour: theme.Colour };

const principals = [_]Principal{
    .{ .kind = "Human", .name = "You", .role = "Full authority", .colour = theme.human },
    .{ .kind = "Agent", .name = "Planner", .role = "Scoped, revocable", .colour = theme.agent },
    .{ .kind = "Application", .name = "Itinerary", .role = "Sandboxed", .colour = theme.teal },
    .{ .kind = "Service", .name = "Airline", .role = "Reached via bridge", .colour = theme.amber },
    .{ .kind = "Organization", .name = "Work", .role = "Managed policy", .colour = theme.coral },
    .{ .kind = "Device", .name = "This phone", .role = "Trusted endpoint", .colour = theme.human },
    .{ .kind = "Session", .name = "Focus", .role = "Ephemeral, isolated", .colour = theme.agent_soft },
};

fn renderPrincipals(target: *Framebuffer) void {
    header(target, "Principals", "First-class citizens");

    var y: i32 = 168;
    for (principals) |p| {
        const c: Rect = .{ .x = 20, .y = y, .w = width - 40, .h = 76 };
        card(target, c, theme.surface);
        // A larger principal chip on the left.
        paint.paint(target, &.{.{ .rounded = .{ .rect = .{ .x = 36, .y = y + 18, .w = 40, .h = 40 }, .radius = 12, .colour = s(p.colour) } }});
        _ = text.draw(target, 92, @floatFromInt(y + 32), p.name, 15, s(theme.text_primary));
        _ = text.draw(target, 92, @floatFromInt(y + 54), p.role, 12, s(theme.text_secondary));
        _ = text.draw(target, rightAlign(p.kind, 11), @floatFromInt(y + 32), p.kind, 11, s(theme.text_tertiary));
        y += 86;
    }
}

const testing = std.testing;

test "each shell screen fills the frame and draws content" {
    for (std.enums.values(Screen)) |screen| {
        var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
        defer target.deinit();
        render(&target, screen);
        // The status bar time is drawn near the top-left.
        var whites: u32 = 0;
        var y: u32 = 20;
        while (y < 120) : (y += 1) {
            var x: u32 = 0;
            while (x < 120) : (x += 1) {
                if (target.get(x, y).r > 200) whites += 1;
            }
        }
        try testing.expect(whites > 10);
    }
}

test "the approval screen paints the two action buttons" {
    var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer target.deinit();
    render(&target, .approval);
    // The Approve button is filled with the agent accent — a purple-ish pixel exists in its band.
    var found = false;
    var y: u32 = 520;
    while (y < 564 and !found) : (y += 1) {
        var x: u32 = 200;
        while (x < 350) : (x += 1) {
            const p = target.get(x, y);
            if (p.b > p.r and p.b > 120) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}

test "the ledger marks a denied action in the denial colour" {
    var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer target.deinit();
    render(&target, .ledger);
    // Somewhere on the screen a reddish denial pixel exists.
    var found = false;
    var y: u32 = 200;
    while (y < 620 and !found) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const p = target.get(x, y);
            if (p.r > 200 and p.g < 140 and p.b < 140) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}
