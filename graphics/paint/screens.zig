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
pub const Screen = enum { approval, ledger, principals, settings, store };

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
        .settings => renderSettings(target),
        .store => renderStore(target),
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

/// One activity-ledger row as the screen consumes it — a view model, not a control-plane type. The
/// live shell populates these from the real audit ledger; the demo data is the same shape.
pub const LedgerRow = struct {
    actor: []const u8,
    action: []const u8,
    capability: []const u8,
    outcome: []const u8,
    colour: theme.Colour,
    denied: bool,
};

/// Demonstration rows used when the ledger is rendered standalone, without a running control plane.
pub const demo_ledger_rows = [_]LedgerRow{
    .{ .actor = "Planner", .action = "read calendar", .capability = "calendar.read", .outcome = "ok", .colour = theme.agent, .denied = false },
    .{ .actor = "You", .action = "approved a payment", .capability = "payments", .outcome = "once", .colour = theme.human, .denied = false },
    .{ .actor = "Travel agent", .action = "confirm venue", .capability = "network.call", .outcome = "approved", .colour = theme.agent, .denied = false },
    .{ .actor = "Docs agent", .action = "read mail", .capability = "mail.read", .outcome = "denied", .colour = theme.denied, .denied = true },
    .{ .actor = "Planner", .action = "arrange focus", .capability = "calendar.write", .outcome = "ok", .colour = theme.agent, .denied = false },
};

/// Renders the full activity screen from a set of rows — the wallpaper, status bar, header, filter
/// chips, and one card per row. This is the entry point the live shell calls with real ledger data.
pub fn renderActivity(target: *Framebuffer, rows: []const LedgerRow) void {
    wallpaper(target);
    statusBar(target);
    activityContent(target, rows);
}

fn renderLedger(target: *Framebuffer) void {
    activityContent(target, &demo_ledger_rows);
}

fn activityContent(target: *Framebuffer, rows: []const LedgerRow) void {
    header(target, "Activity", "Who acted, under which capability");

    // Filter chips.
    chip(target, .{ .x = 24, .y = 150, .w = 60, .h = 30 }, "All", true);
    chip(target, .{ .x = 92, .y = 150, .w = 84, .h = 30 }, "Agents", false);
    chip(target, .{ .x = 184, .y = 150, .w = 80, .h = 30 }, "Denied", false);

    var y: i32 = 200;
    for (rows) |r| {
        const c: Rect = .{ .x = 20, .y = y, .w = width - 40, .h = 64 };
        card(target, c, theme.surface);
        dot(target, 44, @floatFromInt(y + 24), r.colour);
        _ = text.draw(target, 62, @floatFromInt(y + 28), r.actor, 14, s(theme.text_primary));
        _ = text.draw(target, 62, @floatFromInt(y + 50), r.action, 12, s(theme.text_secondary));
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

/// One principal as the inspector shows it — a view model the live shell populates from the real
/// registry.
pub const Principal = struct { kind: []const u8, name: []const u8, role: []const u8, colour: theme.Colour };

pub const demo_principals = [_]Principal{
    .{ .kind = "Human", .name = "You", .role = "Full authority", .colour = theme.human },
    .{ .kind = "Agent", .name = "Planner", .role = "Scoped, revocable", .colour = theme.agent },
    .{ .kind = "Application", .name = "Itinerary", .role = "Sandboxed", .colour = theme.teal },
    .{ .kind = "Service", .name = "Airline", .role = "Reached via bridge", .colour = theme.amber },
    .{ .kind = "Organization", .name = "Work", .role = "Managed policy", .colour = theme.coral },
    .{ .kind = "Device", .name = "This phone", .role = "Trusted endpoint", .colour = theme.human },
    .{ .kind = "Session", .name = "Focus", .role = "Ephemeral, isolated", .colour = theme.agent_soft },
};

/// Renders the full principals screen from a set of principals — the entry point the live shell calls.
pub fn renderPrincipalsScreen(target: *Framebuffer, list: []const Principal) void {
    wallpaper(target);
    statusBar(target);
    principalsContent(target, list);
}

fn renderPrincipals(target: *Framebuffer) void {
    principalsContent(target, &demo_principals);
}

fn principalsContent(target: *Framebuffer, list: []const Principal) void {
    header(target, "Principals", "First-class citizens");

    var y: i32 = 168;
    for (list) |p| {
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

// --- Settings ---

const Section = struct { title: []const u8, subtitle: []const u8, colour: theme.Colour };

const sections = [_]Section{
    .{ .title = "Identity", .subtitle = "Who you are to the system", .colour = theme.human },
    .{ .title = "Privacy & data", .subtitle = "Nothing leaves without a reason", .colour = theme.teal },
    .{ .title = "Capabilities & grants", .subtitle = "Scoped and revocable", .colour = theme.agent },
    .{ .title = "Endpoints & devices", .subtitle = "Trusted screens for your world", .colour = theme.human },
    .{ .title = "Apps & compatibility", .subtitle = "Everything runs contained", .colour = theme.coral },
    .{ .title = "Appearance", .subtitle = "Yours to tune", .colour = theme.agent_soft },
    .{ .title = "Accessibility", .subtitle = "Built in, never bolted on", .colour = theme.teal_bright },
    .{ .title = "Software & updates", .subtitle = "Atomic and reversible", .colour = theme.amber },
    .{ .title = "Security", .subtitle = "Keys and attestation", .colour = theme.denied },
    .{ .title = "Agent policy", .subtitle = "How agents may act", .colour = theme.agent },
};

fn renderSettings(target: *Framebuffer) void {
    header(target, "Settings", "Yours, and only where you allow");

    var y: i32 = 158;
    for (sections) |section| {
        const c: Rect = .{ .x = 20, .y = y, .w = width - 40, .h = 58 };
        card(target, c, theme.surface);
        // A rounded colour chip marking the section.
        paint.paint(target, &.{.{ .rounded = .{ .rect = .{ .x = 36, .y = y + 15, .w = 28, .h = 28 }, .radius = 9, .colour = s(section.colour) } }});
        _ = text.draw(target, 80, @floatFromInt(y + 26), section.title, 14, s(theme.text_primary));
        _ = text.draw(target, 80, @floatFromInt(y + 46), section.subtitle, 11, s(theme.text_secondary));
        // Chevron.
        vector.strokePolyline(target, &.{
            .{ .x = @floatFromInt(@as(i32, @intCast(width)) - 44), .y = @floatFromInt(y + 22) },
            .{ .x = @floatFromInt(@as(i32, @intCast(width)) - 38), .y = @floatFromInt(y + 29) },
            .{ .x = @floatFromInt(@as(i32, @intCast(width)) - 44), .y = @floatFromInt(y + 36) },
        }, 2, s(theme.text_tertiary), false);
        y += 66;
    }
}

// --- Store ---

/// What a store catalog entry may offer, mirroring the store's install decision: an app that passed
/// review installs directly, an external source must be acknowledged first, an unreviewed one is
/// blocked.
pub const StoreAction = enum { get, acknowledge, blocked };

/// One store catalog entry as the screen shows it — a view model the live shell populates from the
/// real store decision modules.
pub const StoreEntry = struct {
    name: []const u8,
    publisher: []const u8,
    badge: []const u8,
    action: StoreAction,
    colour: theme.Colour,
};

pub const demo_store_entries = [_]StoreEntry{
    .{ .name = "Itinerary", .publisher = "Reviewed \u{00B7} signed", .badge = "Reviewed", .action = .get, .colour = theme.teal },
    .{ .name = "Ledger Notes", .publisher = "Reviewed \u{00B7} signed", .badge = "Reviewed", .action = .get, .colour = theme.agent },
    .{ .name = "Field Tools", .publisher = "Outside source", .badge = "Sideload", .action = .acknowledge, .colour = theme.amber },
    .{ .name = "Unknown Build", .publisher = "Unreviewed source", .badge = "Blocked", .action = .blocked, .colour = theme.denied },
    .{ .name = "Trip Planner", .publisher = "Reviewed \u{00B7} signed", .badge = "Reviewed", .action = .get, .colour = theme.coral },
};

fn actionLabel(action: StoreAction) []const u8 {
    return switch (action) {
        .get => "Get",
        .acknowledge => "Review",
        .blocked => "Blocked",
    };
}

fn actionColour(action: StoreAction) theme.Colour {
    return switch (action) {
        .get => theme.agent,
        .acknowledge => theme.amber,
        .blocked => theme.surface_raised,
    };
}

/// Renders the full store screen from a set of catalog entries — the entry point the live shell calls
/// with entries whose install action came from the real store decision modules.
pub fn renderStoreScreen(target: *Framebuffer, entries: []const StoreEntry) void {
    wallpaper(target);
    statusBar(target);
    storeContent(target, entries);
}

fn renderStore(target: *Framebuffer) void {
    storeContent(target, &demo_store_entries);
}

fn storeContent(target: *Framebuffer, entries: []const StoreEntry) void {
    header(target, "Store", "Reviewed, signed, contained");

    var y: i32 = 168;
    for (entries) |entry| {
        const c: Rect = .{ .x = 20, .y = y, .w = width - 40, .h = 78 };
        card(target, c, theme.surface);
        // App tile chip.
        paint.paint(target, &.{.{ .rounded = .{ .rect = .{ .x = 36, .y = y + 17, .w = 44, .h = 44 }, .radius = 12, .colour = s(entry.colour) } }});
        _ = text.draw(target, 96, @floatFromInt(y + 32), entry.name, 15, s(theme.text_primary));
        _ = text.draw(target, 96, @floatFromInt(y + 54), entry.publisher, 12, s(theme.text_secondary));
        // Install action pill on the right.
        const label = actionLabel(entry.action);
        const pill_w: u32 = 84;
        const pill: Rect = .{ .x = @as(i32, @intCast(width)) - 20 - @as(i32, @intCast(pill_w)), .y = y + 22, .w = pill_w, .h = 34 };
        const filled = entry.action == .get;
        button(target, pill, label, filled, actionColour(entry.action));
        y += 88;
    }
}

const testing = std.testing;

test "the store screen renders a catalog with an install action" {
    var target = try Framebuffer.init(testing.allocator, width, height, s(theme.base));
    defer target.deinit();
    render(&target, .store);
    // A get pill is filled with the agent accent somewhere on screen.
    var found = false;
    var y: u32 = 168;
    while (y < 700 and !found) : (y += 1) {
        var x: u32 = @intCast(width - 100);
        while (x < width - 20) : (x += 1) {
            const p = target.get(x, y);
            if (p.b > p.r and p.b > 150) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}

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
