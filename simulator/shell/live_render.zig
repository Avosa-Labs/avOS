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

    var y: i32 = 120;
    for (rows.items) |row| {
        const rect = card(screen, y, 58);
        vector.fillDisc(screen, @floatFromInt(rect.x + 22), @floatFromInt(rect.y + 29), 5, s(row.colour));
        _ = text.draw(screen, @floatFromInt(rect.x + 38), @floatFromInt(rect.y + 25), row.actor, 12.5, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 38), @floatFromInt(rect.y + 42), row.action, 10.5, s(theme.screen_text_muted));
        const badge = row.outcome.text;
        const bw = text.measure(badge, 10.5);
        const hue = if (row.outcome.denied) theme.denied else theme.teal;
        _ = text.draw(screen, rightF(rect) - 18 - bw, @floatFromInt(rect.y + 34), badge, 10.5, s(hue));
        y += @as(i32, @intCast(rect.h)) + 8;
    }
}

pub fn renderPrincipals(gpa: std.mem.Allocator, screen: *Framebuffer, host: *Host) !void {
    header(screen, "People & agents", "Everyone here is a first-class citizen");

    var list: std.ArrayList(struct { kind: []const u8, name: []const u8, role: []const u8, colour: theme.Colour }) = .empty;
    defer list.deinit(gpa);

    if (host.registry.lookup(host.human)) |human| {
        try list.append(gpa, .{ .kind = kindName(human.kind), .name = "You", .role = roleText(human.kind), .colour = kindColour(human.kind) });
    }
    for (host.agents.items) |agent| {
        const principal = host.registry.lookup(agent.id) orelse continue;
        try list.append(gpa, .{ .kind = kindName(principal.kind), .name = principal.display_name, .role = roleText(principal.kind), .colour = kindColour(principal.kind) });
    }

    var y: i32 = 120;
    for (list.items) |p| {
        const rect = card(screen, y, 64);
        vector.fillDisc(screen, @floatFromInt(rect.x + 30), @floatFromInt(rect.y + 32), 14, s(p.colour));
        _ = text.draw(screen, @floatFromInt(rect.x + 56), @floatFromInt(rect.y + 26), p.name, 13, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 56), @floatFromInt(rect.y + 44), p.role, 10.5, s(theme.screen_text_muted));
        _ = text.draw(screen, rightF(rect) - 18 - text.measure(p.kind, 10), @floatFromInt(rect.y + 37), p.kind, 10, s(p.colour));
        y += @as(i32, @intCast(rect.h)) + 8;
    }
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

    // Approve / hold buttons.
    const by: i32 = rect.y + @as(i32, @intCast(rect.h)) - 52;
    const half: u32 = (@as(u32, @intCast(rect.w)) - 12) / 2;
    paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = rect.x, .y = by, .w = half, .h = 40 }, .radius = theme.radius_lg, .colour = s(theme.agent) } }});
    text.drawCentred(screen, @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(half)) / 2, @floatFromInt(by + 25), "Approve", 12.5, s(theme.screen_card));
    paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = rect.x + @as(i32, @intCast(half)) + 12, .y = by, .w = half, .h = 40 }, .radius = theme.radius_lg, .colour = s(theme.screen_hairline) } }});
    text.drawCentred(screen, @as(f32, @floatFromInt(rect.x + @as(i32, @intCast(half)) + 12)) + @as(f32, @floatFromInt(half)) / 2, @floatFromInt(by + 25), "Hold", 12.5, s(theme.screen_text));
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

    var y: i32 = 120;
    for (catalog) |item| {
        // A Store install proceeds; a sideload needs the person's acknowledgement, and
        // an unacknowledged sideload is blocked.
        const needs_ack = install_source.installNeedsAcknowledgement(item.source);
        const blocked = needs_ack and !item.acknowledged;
        const action: []const u8 = if (blocked) "Blocked" else if (needs_ack) "Acknowledge" else "Get";
        const rect = card(screen, y, 66);
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
        y += @as(i32, @intCast(rect.h)) + 8;
    }
}

/// The name of the first agent in the run, for app screens to attribute work to.
fn firstAgentName(host: *Host) []const u8 {
    if (host.agents.items.len == 0) return "your agent";
    const principal = host.registry.lookup(host.agents.items[0].id) orelse return "your agent";
    return principal.display_name;
}

/// A pill label — a small rounded tag with centred text, for a status like a live badge.
fn pill(screen: *Framebuffer, x: i32, y: i32, wpx: u32, label: []const u8, colour: theme.Colour) void {
    paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = x, .y = y, .w = wpx, .h = 22 }, .radius = 11, .colour = sa(colour, 34) } }});
    text.drawCentred(screen, @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(wpx)) / 2.0, @floatFromInt(y + 15), label, 10, s(colour));
}

fn sa(colour: theme.Colour, alpha: u8) graphics.framebuffer.Rgba {
    return .{ .r = colour.red, .g = colour.green, .b = colour.blue, .a = alpha };
}

/// Phone: a call the agent screened, transcribing live. The agent is a real principal
/// from the run; the "listening" dot breathes so the screen reads as alive.
pub fn renderPhone(screen: *Framebuffer, host: *Host, t: f32) void {
    header(screen, "Phone", "Calls your agent screens");
    const cx: f32 = @floatFromInt(width_screen() / 2);

    text.drawCentred(screen, cx, 210, "Clinic", 30, s(theme.screen_text));
    var by: [96]u8 = undefined;
    const by_line = std.fmt.bufPrint(&by, "Screened by {s}", .{firstAgentName(host)}) catch "Screened by your agent";
    text.drawCentred(screen, cx, 238, by_line, 13, s(theme.agent));

    // The listening pulse — a dot that breathes.
    const pulse = 0.5 + 0.5 * @sin(t * 3.0);
    vector.fillDisc(screen, cx - 44, 268, 5.0 + pulse * 2.0, s(theme.teal));
    text.drawCentred(screen, cx + 6, 273, "listening", 11, s(theme.screen_text_muted));

    const c = card(screen, 300, 150);
    _ = text.draw(screen, @floatFromInt(c.x + 20), @floatFromInt(c.y + 28), "Live transcript", 11, s(theme.screen_text_muted));
    _ = text.draw(screen, @floatFromInt(c.x + 20), @floatFromInt(c.y + 58), "\u{201C}Confirming your appointment", 13, s(theme.screen_text));
    _ = text.draw(screen, @floatFromInt(c.x + 20), @floatFromInt(c.y + 80), "for Thursday at ten.\u{201D}", 13, s(theme.screen_text));
    _ = text.draw(screen, @floatFromInt(c.x + 20), @floatFromInt(c.y + 122), "Proposed a calendar hold", 12, s(theme.agent));

    // The end-call control.
    const end_w: u32 = 88;
    const end_x: i32 = @intFromFloat(cx - @as(f32, @floatFromInt(end_w)) / 2.0);
    paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = end_x, .y = 500, .w = end_w, .h = 46 }, .radius = 22, .colour = s(theme.denied) } }});
    text.drawCentred(screen, cx, 528, "End", 13, s(theme.text_primary));
}

/// Messages: threads the agent triaged, one drafted reply held for approval.
pub fn renderMessages(screen: *Framebuffer, host: *Host) void {
    header(screen, "Messages", "Triaged by your agent");
    const agent = firstAgentName(host);

    const Thread = struct { who: []const u8, note: []const u8, held: bool, colour: theme.Colour };
    const threads = [_]Thread{
        .{ .who = "Venue \u{00B7} Lisbon", .note = "Reply drafted, awaiting you", .held = true, .colour = theme.agent },
        .{ .who = "Sam", .note = "Read \u{00B7} nothing needed", .held = false, .colour = theme.teal },
        .{ .who = "Airline", .note = "Summarised the change", .held = false, .colour = theme.teal },
    };

    var y: i32 = 120;
    for (threads) |th| {
        const rect = card(screen, y, 66);
        vector.fillDisc(screen, @floatFromInt(rect.x + 28), @floatFromInt(rect.y + 33), 13, s(th.colour));
        _ = text.draw(screen, @floatFromInt(rect.x + 52), @floatFromInt(rect.y + 27), th.who, 13, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 52), @floatFromInt(rect.y + 46), th.note, 10.5, s(theme.screen_text_muted));
        if (th.held) pill(screen, rightI(rect) - 66, rect.y + 22, 48, "Hold", theme.agent);
        y += @as(i32, @intCast(rect.h)) + 8;
    }

    var note: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&note, "{s} sends nothing without you", .{agent}) catch "Sends nothing without you";
    text.drawCentred(screen, @floatFromInt(width_screen() / 2), @floatFromInt(y + 34), line, 11, s(theme.screen_text_muted));
}

/// Camera: capture, never without the in-use light. The indicator glows so the promise
/// is visible.
pub fn renderCamera(screen: *Framebuffer, host: *Host, t: f32) void {
    header(screen, "Camera", "Nothing captured without the light");
    const cx: f32 = @floatFromInt(width_screen() / 2);

    // The viewfinder.
    const vf: graphics.paint.Rect = .{ .x = pad, .y = 130, .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = 300 };
    paint.paint(screen, &.{.{ .rounded_vgradient = .{ .rect = vf, .radius = theme.radius_xl, .top = s(theme.panel), .bottom = s(theme.base) } }});

    // The in-use indicator: a glowing dot, unbypassable.
    const glow = 0.5 + 0.5 * @sin(t * 2.4);
    vector.fillDisc(screen, @floatFromInt(vf.x + 22), @floatFromInt(vf.y + 24), 9.0 + glow * 2.0, sa(theme.denied, 90));
    vector.fillDisc(screen, @floatFromInt(vf.x + 22), @floatFromInt(vf.y + 24), 5, s(theme.denied));
    _ = text.draw(screen, @floatFromInt(vf.x + 40), @floatFromInt(vf.y + 29), "In use", 11, s(theme.text_primary));

    var by: [96]u8 = undefined;
    const by_line = std.fmt.bufPrint(&by, "{s} framed this shot", .{firstAgentName(host)}) catch "Framed by your agent";
    text.drawCentred(screen, cx, @floatFromInt(vf.y + @as(i32, @intCast(vf.h)) - 24), by_line, 12, s(theme.text_secondary));

    // The shutter.
    vector.strokeCircle(screen, cx, 490, 30, 4, s(theme.screen_text));
    vector.fillDisc(screen, cx, 490, 22, s(theme.screen_text));
    text.drawCentred(screen, cx, 548, "Tap to capture \u{00B7} held for you", 11, s(theme.screen_text_muted));
}

