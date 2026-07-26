//! Rendering the designed surfaces from a real control-plane run, framed as the phone.
//!
//! This is the bridge between the control plane and the render layer, shared by every front end: the
//! headless frame writer, the whole-session renderer, and the windowed desktop shell all call these
//! functions. Each takes a live `Host` — a run of the canonical scenario, with its real human and
//! agents, one action denied and one held for approval — and renders one designed surface from that
//! run's real audit ledger, registry, and store decisions. Every surface is drawn on the light phone
//! screen and composited into the device frame (dark bezel on a dark desktop), so the running OS shows
//! the design: a light, agent-native handset with the real agents doing the real work inside it.
//!
//! These functions decide nothing; they read the run's state and paint it. `t` is elapsed seconds, so
//! the living motion (breathing dots, the turning orb) advances; a still frame passes 0.

const std = @import("std");
const simulator = @import("simulator");
const graphics = @import("graphics");
const design = @import("design");
const applications = @import("applications");

pub const Host = simulator.host.Host;
const Framebuffer = graphics.framebuffer.Framebuffer;
const phone = graphics.phone;
const logo = graphics.logo;
const home = graphics.home;
const paint = graphics.paint;
const vector = graphics.vector;
const text = graphics.font;
const theme = design.theme;

/// The render target is the whole window: the framed device on its desktop.
pub const width: u32 = phone.window_w;
pub const height: u32 = phone.window_h;

const max_rows: usize = 6;

/// The surfaces the shell can show.
pub const Surface = enum { boot, home, activity, approval, principals, store, rest, phone, messages, camera };

/// Runs the canonical scenario into a fresh host. The caller owns it and must `deinit`.
pub fn runScenario(host: *Host, gpa: std.mem.Allocator) !void {
    Host.init(host, gpa, .{ .seed = 0x51 });
    _ = try simulator.canonical.run(host);
}

fn s(colour: theme.Colour) graphics.framebuffer.Rgba {
    return paint.sample(colour);
}

/// Renders a surface into the window `target`, from the run's real state, at time `t`.
pub fn renderSurface(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host, surface: Surface, t: f32) !void {
    phone.renderDevice(target);

    var screen = try phone.blankScreen(gpa);
    defer screen.deinit();

    switch (surface) {
        .boot => renderBoot(&screen, t),
        .rest => renderRest(&screen),
        else => {
            phone.screenWash(&screen);
            phone.statusBar(&screen);
            switch (surface) {
                .home => renderHome(&screen, host, t),
                .activity => try renderActivity(gpa, &screen, host),
                .approval => renderApproval(&screen, host),
                .principals => try renderPrincipals(gpa, &screen, host),
                .store => renderStore(&screen),
                .phone => renderPhone(&screen, host, t),
                .messages => renderMessages(&screen, host),
                .camera => renderCamera(&screen, host, t),
                else => unreachable,
            }
            phone.homeIndicator(&screen);
        },
    }

    phone.composite(target, screen);
}

// --- Mappings from control-plane enums to the design's accent language ---

fn kindColour(kind: anytype) theme.Colour {
    return switch (kind) {
        .human => theme.human,
        .agent => theme.agent,
        .application => theme.teal,
        .service => theme.amber,
        .organization => theme.coral,
        .device => theme.human,
        .session => theme.agent_soft,
    };
}

fn actionText(action: anytype) []const u8 {
    return switch (action) {
        .authenticated => "authenticated",
        .capability_issued => "issued a capability",
        .capability_delegated => "delegated a capability",
        .capability_used => "used a capability",
        .capability_revoked => "revoked a capability",
        .capability_expired => "a capability expired",
        .task_created => "created a task",
        .task_transitioned => "advanced a task",
        .task_cancelled => "cancelled a task",
        .task_completed => "completed a task",
        .model_invoked => "invoked a model",
        .tool_invoked => "invoked a tool",
        .action_denied => "was denied",
        .approval_requested => "requested approval",
        .approval_decided => "decided an approval",
        else => "acted",
    };
}

const OutcomeView = struct { text: []const u8, denied: bool };

fn outcomeView(outcome: anytype) OutcomeView {
    return switch (outcome) {
        .succeeded => .{ .text = "ok", .denied = false },
        .denied => .{ .text = "denied", .denied = true },
        .awaiting_approval => .{ .text = "held", .denied = false },
        .cancelled => .{ .text = "cancelled", .denied = false },
        .failed => .{ .text = "failed", .denied = true },
        .outcome_unknown => .{ .text = "unknown", .denied = false },
    };
}

fn surfaced(action: anytype) bool {
    return switch (action) {
        .capability_used, .action_denied, .approval_requested, .approval_decided, .task_completed, .model_invoked => true,
        else => false,
    };
}

fn roleText(kind: anytype) []const u8 {
    return switch (kind) {
        .human => "Full authority",
        .agent => "Scoped, revocable",
        .application => "Sandboxed",
        .service => "Reached via bridge",
        .organization => "Managed policy",
        .device => "Trusted endpoint",
        .session => "Ephemeral, isolated",
    };
}

fn kindName(kind: anytype) []const u8 {
    return switch (kind) {
        .human => "Human",
        .agent => "Agent",
        .application => "Application",
        .service => "Service",
        .organization => "Organization",
        .device => "Device",
        .session => "Session",
    };
}

// --- Light-screen chrome shared by the list surfaces ---

const pad: i32 = 22;

/// A screen header: a large title and a subtitle, below the status bar.
fn header(screen: *Framebuffer, title: []const u8, subtitle: []const u8) void {
    _ = text.draw(screen, @floatFromInt(pad), 74, title, 22, s(theme.screen_text));
    _ = text.draw(screen, @floatFromInt(pad), 96, subtitle, 11.5, s(theme.screen_text_muted));
}

/// A white card the width of the content column.
fn card(screen: *Framebuffer, y: i32, h: u32) graphics.paint.Rect {
    const rect: graphics.paint.Rect = .{ .x = pad, .y = y, .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = h };
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = .{ .x = rect.x, .y = rect.y + 6, .w = @intCast(rect.w), .h = h },
        .radius = theme.radius_xl,
        .colour = .{ .r = 0x6a, .g = 0x4b, .b = 0xb0, .a = 18 },
    } }});
    paint.paint(screen, &.{.{ .rounded = .{ .rect = rect, .radius = theme.radius_xl, .colour = s(theme.screen_card) } }});
    return rect;
}

fn width_screen() u32 {
    return theme.screen_w;
}

/// The right edge of a card, in float, avoiding i32/u32 mixing.
fn rightF(rect: graphics.paint.Rect) f32 {
    return @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w));
}

fn rightI(rect: graphics.paint.Rect) i32 {
    return rect.x + @as(i32, @intCast(rect.w));
}

// --- Surfaces ---

pub fn renderBoot(screen: *Framebuffer, t: f32) void {
    paint.paint(screen, &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 0, .w = phone.screen_w, .h = phone.screen_h }, .colour = s(theme.base) } }});
    const cx: f32 = @floatFromInt(phone.screen_w / 2);
    const cy: f32 = @floatFromInt(phone.screen_h / 2);
    const mark_r: f32 = 64.0;
    // A soft glow behind the mark that breathes, in the logo's own blue.
    const pulse = 0.5 + 0.5 * @sin(t * 1.4);
    var g: u8 = 0;
    while (g < 4) : (g += 1) {
        const r = (mark_r + 84.0 + pulse * 20.0) - @as(f32, @floatFromInt(g)) * 30.0;
        vector.fillDisc(screen, cx, cy, r, .{ .r = theme.logo.top.red, .g = theme.logo.top.green, .b = theme.logo.top.blue, .a = 20 });
    }
    // The brand mark.
    logo.draw(screen, cx, cy, mark_r);
    text.drawCentred(screen, cx, cy + mark_r + 58.0, "Starting your world", 15, s(theme.text_primary));
}

pub fn renderRest(screen: *Framebuffer) void {
    paint.paint(screen, &.{.{ .vgradient = .{ .rect = .{ .x = 0, .y = 0, .w = phone.screen_w, .h = phone.screen_h }, .top = s(theme.panel), .bottom = s(theme.base) } }});
    const cx: f32 = @floatFromInt(phone.screen_w / 2);
    text.drawCentred(screen, cx, @floatFromInt(phone.screen_h / 2 - 8), "Everything handled.", 18, s(theme.text_primary));
    text.drawCentred(screen, cx, @floatFromInt(phone.screen_h / 2 + 24), "Hello, world.", 14, s(theme.text_secondary));
}

pub fn renderHome(screen: *Framebuffer, host: *Host, t: f32) void {
    var greeting: []const u8 = "Good morning";
    var buf: [96]u8 = undefined;
    if (host.registry.lookup(host.human)) |human| {
        greeting = std.fmt.bufPrint(&buf, "Good morning, {s}", .{human.display_name}) catch "Good morning";
    }
    var day_buf: [64]u8 = undefined;
    const day_line = std.fmt.bufPrint(&day_buf, "Tuesday \u{00B7} {d} agents working", .{host.agents.items.len}) catch "Tuesday";

    // The held-for-approval action becomes the active task title.
    var active: ?[]const u8 = "Planning your Lisbon trip";
    var index: usize = 0;
    while (index < host.ledger.count()) : (index += 1) {
        const event = host.ledger.at(index) orelse continue;
        if (event.action != .approval_requested) continue;
        active = "Confirming your Lisbon venue";
        break;
    }

    home.render(screen, .{
        .greeting = greeting,
        .day_line = day_line,
        .tasks = &.{
            .{ .title = "Arranging your day", .note = "just now \u{00B7} agents coordinating", .hue = theme.teal },
        },
        .active_title = active,
    }, t);
}

pub fn renderActivity(gpa: std.mem.Allocator, screen: *Framebuffer, host: *Host) !void {
    header(screen, "Activity", "Every action, under a capability");

    var rows: std.ArrayList(struct { actor: []const u8, action: []const u8, outcome: OutcomeView, colour: theme.Colour }) = .empty;
    defer rows.deinit(gpa);

    var index: usize = host.ledger.count();
    while (index > 0 and rows.items.len < max_rows) {
        index -= 1;
        const event = host.ledger.at(index) orelse continue;
        if (!surfaced(event.action)) continue;
        const actor = host.registry.lookup(event.actor) orelse continue;
        const is_human = actor.kind == .human;
        try rows.append(gpa, .{
            .actor = if (is_human) "You" else actor.display_name,
            .action = actionText(event.action),
            .outcome = outcomeView(event.outcome),
            .colour = kindColour(actor.kind),
        });
    }
    std.mem.reverse(@TypeOf(rows.items[0]), rows.items);

    // The ledger is a flex column of equal-height cards; the engine places them.
    var heights: [graphics.stack.max_blocks]f32 = undefined;
    for (rows.items, 0..) |_, i| heights[i] = 58;
    var tops: [graphics.stack.max_blocks]f32 = undefined;
    graphics.stack.columnTops(120, heights[0..rows.items.len], 8, tops[0..rows.items.len]);

    for (rows.items, 0..) |row, i| {
        const rect = card(screen, @intFromFloat(tops[i]), 58);
        vector.fillDisc(screen, @floatFromInt(rect.x + 22), @floatFromInt(rect.y + 29), 5, s(row.colour));
        _ = text.draw(screen, @floatFromInt(rect.x + 38), @floatFromInt(rect.y + 25), row.actor, 12.5, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 38), @floatFromInt(rect.y + 42), row.action, 10.5, s(theme.screen_text_muted));
        const badge = row.outcome.text;
        const bw = text.measure(badge, 10.5);
        const hue = if (row.outcome.denied) theme.denied else theme.teal;
        _ = text.draw(screen, rightF(rect) - 18 - bw, @floatFromInt(rect.y + 34), badge, 10.5, s(hue));
    }
}

// People & agents — "First-class citizens", the seven kinds of principal that inhabit
// the OS as co-equals, verbatim from the design.
const principals_screen: Screen = .{ .title = "People & agents", .sub = "Humans \u{00B7} agents \u{00B7} apps \u{00B7} services \u{00B7} orgs \u{00B7} devices \u{00B7} sessions", .sections = &.{
    .{ .label = "FIRST-CLASS CITIZENS", .rows = &.{
        .{ .title = "Humans", .sub = "you and your contacts", .colour = theme.coral, .value = "1" },
        .{ .title = "Agents", .sub = "planner, route", .colour = theme.agent, .value = "2" },
        .{ .title = "Applications", .sub = "sandboxed", .colour = theme.app_principal, .value = "4" },
        .{ .title = "Services", .sub = "reached via agents", .colour = theme.human, .value = "3" },
        .{ .title = "Organizations", .sub = "work", .colour = theme.coral, .value = "1" },
        .{ .title = "Devices", .sub = "trusted endpoints", .colour = theme.teal, .value = "2" },
        .{ .title = "Sessions", .sub = "ephemeral", .colour = theme.session_principal, .value = "live" },
    } },
} };

pub fn renderPrincipals(gpa: std.mem.Allocator, screen: *Framebuffer, host: *Host) !void {
    _ = gpa;
    _ = host;
    renderScreen(screen, principals_screen);
}

pub fn renderApproval(screen: *Framebuffer, host: *Host) void {
    var agent: []const u8 = "An agent";
    var reaches: []const u8 = "an external destination";
    var index: usize = 0;
    while (index < host.ledger.count()) : (index += 1) {
        const event = host.ledger.at(index) orelse continue;
        if (event.action != .approval_requested) continue;
        if (host.registry.lookup(event.actor)) |actor| agent = actor.display_name;
        if (event.target_kind.len > 0) reaches = event.target_kind;
        break;
    }

    header(screen, "Approval", "Nothing consequential without you");

    const rect = card(screen, 128, 240);
    vector.fillDisc(screen, @floatFromInt(rect.x + 34), @floatFromInt(rect.y + 40), 16, s(theme.agent));
    _ = text.draw(screen, @floatFromInt(rect.x + 60), @floatFromInt(rect.y + 36), agent, 14, s(theme.screen_text));
    _ = text.draw(screen, @floatFromInt(rect.x + 60), @floatFromInt(rect.y + 54), "asks to confirm the venue", 11, s(theme.screen_text_muted));

    const rowsy: i32 = rect.y + 84;
    const facts = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "Action", .v = "confirm attendance" },
        .{ .k = "Reaches", .v = reaches },
        .{ .k = "Scope", .v = "Once \u{00B7} cannot repeat" },
    };
    for (facts, 0..) |f, i| {
        const fy = rowsy + @as(i32, @intCast(i)) * 30;
        _ = text.draw(screen, @floatFromInt(rect.x + 22), @floatFromInt(fy), f.k, 11, s(theme.screen_text_muted));
        _ = text.draw(screen, rightF(rect) - 22 - text.measure(f.v, 11.5), @floatFromInt(fy), f.v, 11.5, s(theme.screen_text));
    }

    // Approve / hold buttons — a flex row of two equal cells split by the layout engine.
    const by: i32 = rect.y + @as(i32, @intCast(rect.h)) - 52;
    var buttons: [2]graphics.flex.Rect = undefined;
    graphics.flex.solve(
        .{ .axis = .row, .gap = 12 },
        &.{ .{ .main = .{ .flex = 1 } }, .{ .main = .{ .flex = 1 } } },
        .{ .w = @floatFromInt(rect.w), .h = 40 },
        &buttons,
    );
    const cells = [_]struct { rect: graphics.flex.Rect, fill: theme.Colour, label: []const u8, ink: theme.Colour }{
        .{ .rect = buttons[0], .fill = theme.agent, .label = "Approve", .ink = theme.screen_card },
        .{ .rect = buttons[1], .fill = theme.screen_hairline, .label = "Hold", .ink = theme.screen_text },
    };
    for (cells) |cell| {
        const x: i32 = rect.x + @as(i32, @intFromFloat(cell.rect.x));
        paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = x, .y = by, .w = @intFromFloat(cell.rect.w), .h = 40 }, .radius = theme.radius_lg, .colour = s(cell.fill) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(x)) + cell.rect.w / 2, @floatFromInt(by + 25), cell.label, 12.5, s(cell.ink));
    }
}

pub fn renderStore(screen: *Framebuffer) void {
    header(screen, "Store", "Reviewed, signed, and sandboxed");

    const install_source = applications.store;
    const Catalog = struct { name: []const u8, publisher: []const u8, source: install_source.Source, acknowledged: bool, colour: theme.Colour };
    const catalog = [_]Catalog{
        .{ .name = "Itinerary", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.teal },
        .{ .name = "Ledger Notes", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.agent },
        .{ .name = "Field Tools", .publisher = "Outside source", .source = .sideload, .acknowledged = true, .colour = theme.amber },
        .{ .name = "Unknown Build", .publisher = "Unreviewed source", .source = .sideload, .acknowledged = false, .colour = theme.denied },
    };

    var heights: [graphics.stack.max_blocks]f32 = undefined;
    for (catalog, 0..) |_, i| heights[i] = 66;
    var tops: [graphics.stack.max_blocks]f32 = undefined;
    graphics.stack.columnTops(120, heights[0..catalog.len], 8, tops[0..catalog.len]);

    for (catalog, 0..) |item, i| {
        // A Store install proceeds; a sideload needs the person's acknowledgement, and
        // an unacknowledged sideload is blocked.
        const needs_ack = install_source.installNeedsAcknowledgement(item.source);
        const blocked = needs_ack and !item.acknowledged;
        const action: []const u8 = if (blocked) "Blocked" else if (needs_ack) "Acknowledge" else "Get";
        const rect = card(screen, @intFromFloat(tops[i]), 66);
        paint.paint(screen, &.{.{ .rounded_vgradient = .{
            .rect = .{ .x = rect.x + 16, .y = rect.y + 15, .w = 36, .h = 36 },
            .radius = 10,
            .top = s(item.colour),
            .bottom = s(item.colour),
        } }});
        _ = text.draw(screen, @floatFromInt(rect.x + 64), @floatFromInt(rect.y + 28), item.name, 13, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 64), @floatFromInt(rect.y + 46), item.publisher, 10.5, s(theme.screen_text_muted));
        const hue = if (blocked) theme.denied else theme.agent;
        const bw = text.measure(action, 11);
        paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = rightI(rect) - 20 - @as(i32, @intFromFloat(bw)) - 20, .y = rect.y + 20, .w = @as(u32, @intFromFloat(bw)) + 24, .h = 26 }, .radius = 13, .colour = s(hue) } }});
        text.drawCentred(screen, rightF(rect) - 20 - bw / 2 - 12, @floatFromInt(rect.y + 37), action, 11, s(theme.screen_card));
    }
}

// --- The design's data-driven screen model ---
//
// Every app screen in the design is the same shape: a title and sub, then sections, each
// a small label over rows, and each row a coloured dot, a title, a subtitle, and an
// optional value on the right. Rendering from this model — with content taken verbatim
// from the design — is what makes the apps look and read as the design intends.

const Row = struct { title: []const u8, sub: []const u8, colour: theme.Colour, value: []const u8 = "" };
const Section = struct { label: []const u8, rows: []const Row };
const Screen = struct { title: []const u8, sub: []const u8, sections: []const Section };

fn sa(colour: theme.Colour, alpha: u8) graphics.framebuffer.Rgba {
    return .{ .r = colour.red, .g = colour.green, .b = colour.blue, .a = alpha };
}

/// Renders a design screen: the header, then each section's label and its rows as light
/// cards — a soft colour halo and dot on the left, the title and subtitle, the value on
/// the right in the row's own accent.
fn renderScreen(screen: *Framebuffer, model: Screen) void {
    header(screen, model.title, model.sub);

    // The screen is a flex column of blocks: each section is a label followed by its row
    // cards, with a trailing spacer between sections. The layout engine places the blocks;
    // this only paints them at the tops it returns.
    const Kind = enum { label, card, spacer };
    const Block = struct { kind: Kind, section: usize, row: usize };
    var blocks: [graphics.stack.max_blocks]Block = undefined;
    var heights: [graphics.stack.max_blocks]f32 = undefined;
    var n: usize = 0;
    for (model.sections, 0..) |section, si| {
        blocks[n] = .{ .kind = .label, .section = si, .row = 0 };
        heights[n] = 24;
        n += 1;
        for (section.rows, 0..) |_, ri| {
            blocks[n] = .{ .kind = .card, .section = si, .row = ri };
            heights[n] = 68; // a 60-tall card plus the 8 gap below it
            n += 1;
        }
        blocks[n] = .{ .kind = .spacer, .section = si, .row = 0 };
        heights[n] = 8;
        n += 1;
    }

    var tops: [graphics.stack.max_blocks]f32 = undefined;
    graphics.stack.columnTops(122, heights[0..n], 0, tops[0..n]);

    for (blocks[0..n], 0..) |b, i| {
        const y: i32 = @intFromFloat(tops[i]);
        switch (b.kind) {
            .spacer => {},
            .label => _ = text.draw(screen, @floatFromInt(pad + 4), @floatFromInt(y + 12), model.sections[b.section].label, 10.5, s(theme.screen_label)),
            .card => {
                const row = model.sections[b.section].rows[b.row];
                const rect = card(screen, y, 60);
                // A soft halo behind the dot, in the row's colour, then the dot.
                vector.fillDisc(screen, @floatFromInt(rect.x + 30), @floatFromInt(rect.y + 30), 15, sa(row.colour, 32));
                vector.fillDisc(screen, @floatFromInt(rect.x + 30), @floatFromInt(rect.y + 30), 6, s(row.colour));
                _ = text.draw(screen, @floatFromInt(rect.x + 52), @floatFromInt(rect.y + 26), row.title, 12.5, s(theme.screen_text));
                _ = text.draw(screen, @floatFromInt(rect.x + 52), @floatFromInt(rect.y + 44), row.sub, 10, s(theme.screen_text_muted));
                if (row.value.len > 0) {
                    const vw = text.measure(row.value, 10.5);
                    _ = text.draw(screen, rightF(rect) - 18 - vw, @floatFromInt(rect.y + 35), row.value, 10.5, s(row.colour));
                }
            },
        }
    }
}

// Phone — "Recents", verbatim from the design.
const phone_screen: Screen = .{ .title = "Recents", .sub = "Calls, with context", .sections = &.{
    .{ .label = "TODAY", .rows = &.{
        .{ .title = "Sam", .sub = "12 min \u{00B7} outgoing", .colour = theme.coral, .value = "12:04" },
        .{ .title = "Clinic", .sub = "handled by agent", .colour = theme.teal, .value = "10:40" },
        .{ .title = "Spam blocked \u{00D7}4", .sub = "you were not disturbed", .colour = theme.denied },
    } },
    .{ .label = "SCREENED BY AGENT", .rows = &.{
        .{ .title = "Unknown \u{203A} clinic", .sub = "confirming Thu 3pm \u{00B7} added", .colour = theme.teal, .value = "Kept" },
        .{ .title = "Delivery", .sub = "rescheduled to Fri", .colour = theme.human, .value = "Done" },
    } },
} };

// Messages — the agent-to-agent negotiation, verbatim from the design.
const messages_screen: Screen = .{ .title = "Planner & Airline", .sub = "Negotiated on your behalf", .sections = &.{
    .{ .label = "THREAD", .rows = &.{
        .{ .title = "Seat + bag for LIS?", .sub = "Planner", .colour = theme.agent },
        .{ .title = "12A confirmed, bag added", .sub = "Airline agent \u{00B7} \u{20AC}0", .colour = theme.human },
        .{ .title = "Summarized for you", .sub = "nothing needs action", .colour = theme.teal },
    } },
    .{ .label = "SAM", .rows = &.{
        .{ .title = "see you at lunch!", .sub = "Sam", .colour = theme.coral },
        .{ .title = "booked the corner table", .sub = "you", .colour = theme.human },
    } },
} };

// Camera — "Lens modes", verbatim from the design.
const camera_screen: Screen = .{ .title = "Lens modes", .sub = "One camera, three intents", .sections = &.{
    .{ .label = "MODES", .rows = &.{
        .{ .title = "Lens", .sub = "front \u{00B7} in-screen", .colour = theme.agent, .value = "On" },
        .{ .title = "Describe", .sub = "ask about what you see", .colour = theme.teal },
        .{ .title = "Capture", .sub = "photo \u{00B7} video", .colour = theme.human },
    } },
    .{ .label = "PRIVACY", .rows = &.{
        .{ .title = "Front camera", .sub = "invisible until opened", .colour = theme.coral, .value = "Hidden" },
    } },
} };

pub fn renderPhone(screen: *Framebuffer, host: *Host, t: f32) void {
    _ = host;
    _ = t;
    renderScreen(screen, phone_screen);
}

pub fn renderMessages(screen: *Framebuffer, host: *Host) void {
    _ = host;
    renderScreen(screen, messages_screen);
}

pub fn renderCamera(screen: *Framebuffer, host: *Host, t: f32) void {
    _ = host;
    _ = t;
    renderScreen(screen, camera_screen);
}
